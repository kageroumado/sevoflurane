import Foundation
import os

extension SteamBridge {
    // MARK: - Page sessions

    /// A connection becomes a page on its first message, the shim's hello.
    /// A handshake the gate refused sends nothing and closes, so it never
    /// takes ``newestPage`` from the live page.
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
            // Tunnel commands carry a byte stream, so they leave in arrival
            // order on one worker rather than as free-floating tasks.
            for await raw in tunnelStream {
                await self?.relaySend(raw, from: id)
            }
        })
    }

    /// The first message a page or the relay sends once its socket opens.
    nonisolated static func isHello(_ raw: String) -> Bool {
        jsonObject(raw)?["type"] as? String == "hello"
    }

    /// A page whose calls have nowhere to go is closed at once: the shim
    /// reconnects a second after close, and by then the supervisor may have
    /// the client back.
    private func closeUnlessClientReachable(_ ws: WSConnection) async {
        guard await (try? ensureCDP()) == nil else { return }
        ws.close()
    }

    /// The session is looked up rather than captured: `PageSession` lives in
    /// the actor's region, and a consumer task may not carry a reference to
    /// it across the isolation boundary.
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
                // The shim's `v` is already JSON text (it stringifies before
                // sending); re-encoding it here would double-escape.
                continuation.resume(returning: (
                    ok: request["ok"] as? Bool ?? false,
                    v: request["v"] as? String ?? "null",
                ))
            }
            return
        }
        // Every other command runs on its own task: a SteamClient call that
        // never settles must not stall the ones behind it.
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
            // A client on its way out refuses every call the page still
            // makes, a dozen in a second: said once per closing.
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
                // The shim's promise must settle: a call that timed out or
                // lost its connection rejects there like a Steam error does.
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

    /// How long a forwarded `SteamClient` call may wait for the client's
    /// reply. Generous, because some calls settle only when Steam has
    /// finished a job of its own; the page's promise rejects after this.
    static let forwardBudget: Duration = .seconds(120)

    /// Replays one shim call against the real SharedJSContext.
    ///
    /// Function arguments arrive as `{"__sevoCb": id}` markers; they are
    /// rebuilt on the far side as real functions that push through the
    /// `__sevo` binding, so Steam's own callbacks stream back to the page
    /// that registered them. A registration's handle is retained in
    /// `__sevoRet` so ``unregister(_:cdp:)`` can find it.
    private func forwardSteamClient(
        _ request: [String: Any],
        ws: WSConnection,
        id: ObjectIdentifier,
        cdp: CDPClient,
    ) async throws {
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
        if path == "SteamClient.Apps.RunGame" {
            // The one choke point every launch funnels through — menu bar,
            // the library's Play button, steam://run. Reconcile the renderer
            // tree here, before the call reaches Steam, so a version or
            // renderer change made in Settings takes effect on this launch
            // whatever started it, with no race against the game's DLL load.
            // A bounce (msync, engine) can't be applied inline and stays the
            // launch path's job; only a restage is owed here.
            if BottleGraphics.graphicsChangeSinceBoot().restage {
                if let note = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
                    log(.client, note)
                }
                BottleGraphics.recordBootedSelection()
            }
            onGameLaunch?()
        }
        if path == "SteamClient.Apps.TerminateApp",
           let appID = (request["args"] as? [Any])?.first.flatMap({ ($0 as? NSNumber)?.intValue ?? Int("\($0)") }) {
            // Every stop asked for in the page — the library's Stop button, the
            // menu bar — passes here. The run that ends next a person ended.
            RunLog.noteStopRequest(forApp: appID, by: .player)
        }
        let call = PerfProbe.bridge.beginInterval(
            "SteamClientCall",
            id: PerfProbe.bridge.makeSignpostID(),
            "\(path, privacy: .public)",
        )
        defer { PerfProbe.bridge.endInterval("SteamClientCall", call) }
        let (argsJS, callbacks) = mintArguments(of: request, owner: id)
        let expr = Self.forwardExpression(path: path, handleJS: handleJS, argsJS: argsJS)
        // The handle exists before the await: an unregister or a page close
        // that arrives while the reply is pending finds it, and the reply
        // then sees whether anyone still wants it.
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
                // Unregistered or orphaned while the reply was pending; the
                // client retained the handle a moment ago, so release it.
                registrations.removeValue(forKey: handle)
                _ = try? await cdp.evaluate(Self.remoteUnregister([handle]))
            }
        } else {
            registrations.removeValue(forKey: handle)
        }
        ws.send(text: Self.resultReply(rid: rid, outcome: outcome))
    }

    /// Whether `path` names a member of `SteamClient` by dotted identifiers
    /// alone. The path is spliced into the evaluated expression as source,
    /// so anything else would be code the page chose to run in the client.
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

    /// The call's arguments as JS source, and the callback ids among them,
    /// each now owned by `owner`.
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

    /// The expression that makes one call in SharedJSContext and reports
    /// its outcome as JSON text.
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

    /// Drops a forward that failed or timed out. The client's side of a
    /// registration may still settle later, so a call that could have
    /// produced one is marked dropped over there: the reply path releases
    /// the handle itself when it finds the mark.
    private func abandonRegistration(_ handle: String, hadCallbacks: Bool, cdp: CDPClient) async {
        if let registration = registrations.removeValue(forKey: handle) {
            for cb in registration.callbacks {
                callbackOwner.removeValue(forKey: cb)
            }
        }
        guard hadCallbacks, await !cdp.isClosed else { return }
        _ = try? await withDeadline(.seconds(5)) { try await cdp.evaluate(Self.remoteUnregister([handle])) }
    }

    /// Releases the client's side of each handle: the retained object is
    /// unregistered and dropped from `__sevoRet`. A handle the client has
    /// not retained yet is marked dropped, for the registration's own reply
    /// path to release.
    private static func remoteUnregister(_ handles: [String]) -> String {
        "\(jsonText(handles) ?? "[]").forEach(r => { const h = (window.__sevoRet||{})[r]; "
            + "delete window.__sevoRet[r]; if (h) h.unregister?.(); "
            + "else (window.__sevoDropped = window.__sevoDropped || new Set()).add(r); }); 'ok'"
    }

    /// Releases registrations on the far side and here: their handles are
    /// used and dropped from `__sevoRet`, and their callback ids forgotten.
    /// Without this a page that reloaded, or Steam's own popup that closed,
    /// would leave its handlers firing into the client for the rest of the
    /// session.
    private func unregister(_ handles: [String], cdp: CDPClient) async throws {
        var active: [String] = []
        for handle in handles {
            guard let registration = registrations.removeValue(forKey: handle) else { continue }
            for cb in registration.callbacks {
                callbackOwner.removeValue(forKey: cb)
            }
            // A pending handle has nothing on the far side yet; removing
            // the entry is what makes its reply release the handle.
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
        if let cdp, await !cdp.isClosed {
            try? await unregister(orphaned, cdp: cdp)
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
