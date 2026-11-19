import Foundation
import os

extension SteamBridge {
    // MARK: - Page sessions

    /// A connection becomes a page on its first message, the shim's hello, so
    /// a handshake the gate refused never takes ``newestPage``.
    func attachPage(_ ws: WSConnection, queue: DispatchQueue) {
        let id = ObjectIdentifier(ws)
        let stream = Self.messages(of: ws, on: queue)
        Task { [weak self] in
            var isRegistered = false
            for await message in stream {
                switch message {
                case let .text(raw) where isRegistered:
                    await self?.handlePageMessage(raw, id: id)
                case let .text(raw):
                    guard Self.isHello(raw) else {
                        ws.close()
                        continue
                    }
                    isRegistered = true
                    await self?.registerPage(ws)
                    await self?.closeUnlessClientReachable(ws)
                case .data:
                    break
                case .closed:
                    if isRegistered { await self?.detachPage(id) }
                }
            }
        }
    }

    private func registerPage(_ ws: WSConnection) {
        let (tunnelStream, tunnelContinuation) = AsyncStream.makeStream(of: String.self)
        pageSerial += 1
        let session = PageSession(ws: ws, tunnel: tunnelContinuation, serial: pageSerial)
        let id = ObjectIdentifier(ws)
        pages[id] = session
        newestPage = id
        log(.bridge, "page connected (\(pages.count) total)")

        session.tasks.append(Task { [weak self] in
            // Tunnel commands carry a byte stream, so one worker keeps order.
            for await raw in tunnelStream {
                await self?.relaySend(raw, from: id)
            }
        })
    }

    nonisolated static func isHello(_ raw: String) -> Bool {
        jsonObject(raw)?["type"] as? String == "hello"
    }

    /// Closes a page whose calls have nowhere to go; the shim reconnects a
    /// second later, when the client may be back.
    private func closeUnlessClientReachable(_ ws: WSConnection) async {
        guard await (try? ensureCDP()) == nil else { return }
        ws.close()
    }

    /// Looks the session up by id: `PageSession` lives in the actor's region
    /// and may not cross the isolation boundary.
    private func handlePageMessage(_ raw: String, id: ObjectIdentifier) {
        guard let session = pages[id], let request = Self.jsonObject(raw) else { return }
        let cmd = request["cmd"] as? String ?? ""
        if cmd.hasPrefix("ws_") {
            session.tunnel.yield(raw)
            return
        }
        if cmd == "eval_result" {
            if let eid = request["id"] as? String,
               let continuation = evalPending.removeValue(forKey: eid) {
                evalTimeouts.removeValue(forKey: eid)?.cancel()
                evalPage.removeValue(forKey: eid)
                // `v` is already JSON text; re-encoding would double-escape.
                continuation.resume(returning: (
                    ok: request["ok"] as? Bool ?? false,
                    v: request["v"] as? String ?? "null",
                ))
            }
            return
        }
        // Its own task, so a call that never settles stalls nothing else.
        Task { await self.dispatch(request, ws: session.ws, id: id) }
    }

    private func dispatch(_ request: [String: Any], ws: WSConnection, id: ObjectIdentifier) async {
        guard let cdp = try? await ensureCDP() else { return }
        let cmd = request["cmd"] as? String ?? ""
        do {
            switch cmd {
            case "sc":
                try await forwardSteamClient(request, ws: ws, id: id, cdp: cdp)
            case "sc_unregister":
                if let rid = request["id"] as? Int, let session = pages[id] {
                    try await unregister([Self.handle(session.serial, rid)], cdp: cdp)
                }
            default:
                return
            }
        } catch {
            // A closing client refuses a dozen calls a second: log it once.
            let closing = "\(error)" == "closed"
            if !closing || !saidClientIsClosing {
                log(
                    .bridge,
                    closing
                        ? "the client is closing — the page's calls are refused until it is back"
                        : "dispatch \(cmd) failed: \(error)",
                )
            }
            saidClientIsClosing = closing
            if cmd == "sc", let rid = request["id"] as? Int {
                // The shim's promise must settle, so it rejects like a Steam
                // error.
                ws.send(text: Self.resultReply(rid: rid, outcome: [
                    "ok": false, "e": ["__sevoErr": "Error", "message": "\(error)"],
                ]))
            }
        }
    }

    /// The `sc_result` envelope for one forwarded call's outcome.
    private static func resultReply(rid: Int, outcome: [String: Any]) -> String {
        var reply = #"{"type":"sc_result","id":\#(rid)"#
        if outcome["ok"] as? Bool == true {
            reply += #","value":\#(jsonText(jsonText(outcome["v"]) ?? "null") ?? "\"null\"")}"#
        } else {
            reply += #","error":\#(jsonText(jsonText(outcome["e"]) ?? "null") ?? "\"null\"")}"#
        }
        return reply
    }

    /// How long a forwarded `SteamClient` call may wait; some settle only
    /// after a Steam job finishes.
    static let forwardBudget: Duration = .seconds(120)

    /// Replays one shim call against the real SharedJSContext.
    ///
    /// Function arguments arrive as `{"__sevoCb": id}` markers and are rebuilt
    /// as functions that push through the `__sevo` binding to the page that
    /// registered them. A registration's handle is retained in `__sevoRet`
    /// for ``unregister(_:cdp:)``.
    private func forwardSteamClient(
        _ request: [String: Any],
        ws: WSConnection,
        id: ObjectIdentifier,
        cdp: CDPClient,
    ) async throws {
        var request = request
        guard let rid = request["id"] as? Int,
              let path = request["path"] as? String,
              let session = pages[id] else { return }
        guard Self.isSteamClientPath(path) else {
            log(.bridge, "refused a SteamClient call to a malformed path")
            ws.send(text: Self.resultReply(rid: rid, outcome: [
                "ok": false, "e": ["__sevoErr": "Error", "message": "not a SteamClient method path"],
            ]))
            return
        }
        let handle = Self.handle(session.serial, rid)
        let handleJS = Self.jsonText(handle) ?? "\"?\""
        if await Self.handsOffToSteamForMac(path: path, request: request) {
            // The page's call settles as the client's would.
            ws.send(text: Self.resultReply(rid: rid, outcome: ["ok": true, "v": NSNull()]))
            return
        }
        if let outcome = await Self.answersOnTheMac(path: path, request: request) {
            ws.send(text: Self.resultReply(rid: rid, outcome: outcome))
            return
        }
        if path == "SteamClient.Apps.RunGame" {
            // Every launch passes here. Ready the launch first (a first
            // launch's fixes can pick the renderer), then restage the renderer
            // tree before Steam sees the call, so a Settings change applies to
            // this launch without racing the game's DLL load. A bounce (msync,
            // engine) stays the launch path's job.
            if let launchPreparation, let gameID = (request["args"] as? [Any])?.first {
                await launchPreparation("\(gameID)")
            }
            if BottleGraphics.graphicsChangeSinceBoot().restage {
                if let note = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
                    log(.client, note)
                }
                BottleGraphics.recordBootedSelection()
            }
            await adoptLaunchCommand(beforeRunning: request, cdp: cdp)
            onGameLaunch?()
        }
        if path == "SteamClient.Apps.SetAppLaunchOptions" {
            request = await adoptingLaunchCommand(in: request)
        }
        // Single-game wizards only: a collection install gets no per-game
        // warnings.
        if path == "SteamClient.Installs.OpenInstallWizard", let installGate,
           let appIDs = (request["args"] as? [Any])?.first as? [Any], appIDs.count == 1,
           let appID = (appIDs[0] as? NSNumber)?.intValue,
           await !installGate(appID) {
            log(.client, "install \(appID): canceled at the compatibility warning")
            ws.send(text: Self.resultReply(rid: rid, outcome: ["ok": true, "v": NSNull()]))
            return
        }
        // A shortcut's game id is 64-bit with its top bit set, past Int: read
        // as text and mapped to the adopted program the run is recorded under.
        if path == "SteamClient.Apps.TerminateApp",
           let raw = (request["args"] as? [Any])?.first.map({ ($0 as? NSNumber)?.stringValue ?? "\($0)" }),
           let appID = SteamShortcuts.appID(
               fromSteam: raw, aliases: SteamShortcuts.aliases(AdoptedPrograms.all()),
           ) {
            // Every stop asked for in the page passes here.
            RunLog.noteStopRequest(forApp: appID, by: .player)
            // Ending the processes first (bounded; a holdout is killed) leaves
            // Steam's TerminateProcess nothing to tear down thread by thread,
            // so no crash report is filed (``GameEnding``).
            if let ended = await GameEnding.end(appID: appID).summary {
                log(.client, "stop \(appID): \(ended)")
            }
        }
        let call = PerfProbe.bridge.beginInterval(
            "SteamClientCall",
            id: PerfProbe.bridge.makeSignpostID(),
            "\(path, privacy: .public)",
        )
        defer { PerfProbe.bridge.endInterval("SteamClientCall", call) }
        let (argsJS, callbacks) = mintArguments(of: request, owner: id)
        let expr = Self.forwardExpression(path: path, handleJS: handleJS, argsJS: argsJS)
        // Registered before the await, so an unregister or page close during
        // the call finds it.
        registrations[handle] = Registration(owner: id, callbacks: callbacks, state: .pending)
        let raw: String?
        do {
            raw = try await withDeadline(Self.forwardBudget) { try await cdp.evaluate(expr) }
        } catch {
            await abandonRegistration(handle, hadCallbacks: !callbacks.isEmpty, cdp: cdp)
            throw error
        }
        let outcome = raw.flatMap(Self.jsonObject) ?? ["ok": false, "e": "no result"]
        if outcome["reg"] as? Bool == true {
            if registrations[handle] != nil, pages[id] != nil {
                registrations[handle]?.state = .active
            } else {
                // Unregistered or orphaned while pending: release it.
                registrations.removeValue(forKey: handle)
                _ = try? await cdp.evaluate(Self.remoteUnregister([handle]))
            }
        } else {
            registrations.removeValue(forKey: handle)
        }
        ws.send(text: Self.resultReply(rid: rid, outcome: outcome))
    }

    /// The reply for a call the Mac answers in the client's place: the file
    /// dialog becomes the Mac's panel, and Add desktop shortcut becomes an
    /// alias of the game's bundle on the Mac's desktop. `nil` for any other
    /// call, or a game with no bundle yet.
    private static func answersOnTheMac(path: String, request: [String: Any]) async -> [String: Any]? {
        let argument = (request["args"] as? [Any])?.first
        switch path {
        case "SteamClient.System.OpenFileDialog":
            let options = SteamFileDialogs.Options(argument as? [String: Any] ?? [:])
            guard let chosen = await SteamFileDialogs.choose(options) else {
                return ["ok": false, "e": ["result": SteamFileDialogs.cancelledResult, "message": "cancelled"]]
            }
            return ["ok": true, "v": chosen]
        case "SteamClient.Apps.CreateDesktopShortcutForApp":
            guard let appID = argument.flatMap({ Int("\($0)") }),
                  await DesktopShortcuts.take(appID: appID) else { return nil }
            return ["ok": true, "v": NSNull()]
        default:
            return nil
        }
    }

    /// Whether a `RunGame` goes to Steam for Mac (``MacBuildHandoff``) or a
    /// companion's partner (``CompanionHandoff``) instead of the client.
    private static func handsOffToSteamForMac(path: String, request: [String: Any]) async -> Bool {
        guard path == "SteamClient.Apps.RunGame",
              let appID = (request["args"] as? [Any])?.first.flatMap({ Int("\($0)") }) else { return false }
        if await MacBuildHandoff.takeRunGame(appID: appID) { return true }
        return await CompanionHandoff.takeRunGame(appID: appID)
    }

    /// Whether `path` is `SteamClient` followed by dotted identifiers only.
    /// The path is spliced into evaluated source, so anything else would be
    /// page-chosen code running in the client.
    nonisolated static func isSteamClientPath(_ path: String) -> Bool {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "SteamClient" else { return false }
        return parts.dropFirst().allSatisfy(isIdentifier)
    }

    private nonisolated static func isIdentifier(_ part: Substring) -> Bool {
        guard let first = part.unicodeScalars.first else { return false }
        func isStart(_ scalar: Unicode.Scalar) -> Bool {
            ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || scalar == "_" || scalar == "$"
        }
        return isStart(first) && part.unicodeScalars.dropFirst().allSatisfy { isStart($0) || ("0" ... "9").contains($0) }
    }

    /// The call's arguments as JS source, and its callback ids, now owned by
    /// `owner`.
    private func mintArguments(
        of request: [String: Any], owner: ObjectIdentifier,
    ) -> (argsJS: [String], callbacks: [String]) {
        var argsJS: [String] = []
        var callbacks: [String] = []
        for argument in request["args"] as? [Any] ?? [] {
            if let marker = argument as? [String: Any],
               let cb = marker["__sevoCb"] as? String {
                callbackOwner[cb] = owner
                callbacks.append(cb)
                let cbJSON = Self.jsonText(cb) ?? "\"?\""
                argsJS.append("function(){window.__sevo(JSON.stringify({type:'sc_callback',"
                    + "cb:\(cbJSON),args:window.__sevoEnc(Array.prototype.slice.call(arguments))}))}")
            } else {
                argsJS.append("window.__sevoDec(\(Self.jsonText(argument) ?? "null"))")
            }
        }
        return (argsJS, callbacks)
    }

    private static func forwardExpression(path: String, handleJS: String, argsJS: [String]) -> String {
        """
        (async () => {
          window.__sevoRet = window.__sevoRet || {};
          try {
            const r = await \(path)(\(argsJS.joined(separator: ",")));
            if (r && r.unregister) {
              // A handle the bridge gave up on before this settled is
              // released here, where the object exists.
              if (window.__sevoDropped && window.__sevoDropped.delete(\(handleJS))) {
                r.unregister();
                return JSON.stringify({ok: true, v: null});
              }
              window.__sevoRet[\(handleJS)] = r;
              return JSON.stringify({ok: true, reg: true, v: null});
            }
            return JSON.stringify({ok: true, v: window.__sevoEnc(r)});
          } catch (e) {
            // Steam rejects with plain objects (e.g. {result: n}) that the UI
            // inspects; stringifying them to "[object Object]" destroys the
            // information the caller branches on.
            const payload = (e instanceof Error)
              ? {__sevoErr: 'Error', message: e.message}
              : window.__sevoEnc(e);
            return JSON.stringify({ok: false, e: payload});
          }
        })()
        """
    }

    /// Drops a forward that failed or timed out, marking a possible
    /// registration dropped in the client so its late reply releases it.
    private func abandonRegistration(_ handle: String, hadCallbacks: Bool, cdp: CDPClient) async {
        if let registration = registrations.removeValue(forKey: handle) {
            for cb in registration.callbacks {
                callbackOwner.removeValue(forKey: cb)
            }
        }
        guard hadCallbacks, await !cdp.isClosed else { return }
        _ = try? await withDeadline(.seconds(5)) { try await cdp.evaluate(Self.remoteUnregister([handle])) }
    }

    /// Unregisters each retained handle in the client, or marks one not yet
    /// retained as dropped for its reply path to release.
    private static func remoteUnregister(_ handles: [String]) -> String {
        "\(jsonText(handles) ?? "[]").forEach(r => { const h = (window.__sevoRet||{})[r]; "
            + "delete window.__sevoRet[r]; if (h) h.unregister?.(); "
            + "else (window.__sevoDropped = window.__sevoDropped || new Set()).add(r); }); 'ok'"
    }

    /// Releases registrations in the client and here, so a reloaded page or a
    /// closed popup stops receiving callbacks.
    private func unregister(_ handles: [String], cdp: CDPClient) async throws {
        var active: [String] = []
        for handle in handles {
            guard let registration = registrations.removeValue(forKey: handle) else { continue }
            for cb in registration.callbacks {
                callbackOwner.removeValue(forKey: cb)
            }
            // A pending handle is released by its reply once the entry is gone.
            if registration.state == .active { active.append(handle) }
        }
        guard !active.isEmpty else { return }
        _ = try await cdp.evaluate(Self.remoteUnregister(active))
    }

    private static func handle(_ serial: Int, _ rid: Int) -> String {
        "\(serial)_\(rid)"
    }

    private func detachPage(_ id: ObjectIdentifier) async {
        guard let session = pages.removeValue(forKey: id) else { return }
        if newestPage == id { newestPage = pages.keys.first }
        for (eid, page) in evalPage where page == id {
            finishEval(eid, with: (false, "\"page disconnected\""))
        }
        session.tunnel.finish()
        for task in session.tasks {
            task.cancel()
        }
        let orphaned = registrations.filter { $0.value.owner == id }.map(\.key)
        // Bounded like `abandonRegistration`: a wedged client must not keep the
        // dead page's tunnels open.
        if let cdp, await !cdp.isClosed {
            _ = try? await withDeadline(.seconds(5)) { try await self.unregister(orphaned, cdp: cdp) }
        }
        for handle in orphaned {
            registrations.removeValue(forKey: handle)
        }
        for (cb, owner) in callbackOwner where owner == id {
            callbackOwner.removeValue(forKey: cb)
        }
        for (tid, owner) in tunnelOwner where owner == id {
            tunnelOwner.removeValue(forKey: tid)
            relay?.send(text: #"{"cmd":"ws_close","id":\#(Self.jsonText(tid) ?? "\"?\"")}"#)
        }
        log(.bridge, "page disconnected (\(pages.count) left)")
    }
}
