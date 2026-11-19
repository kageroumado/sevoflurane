import Foundation
import os

extension SteamBridge {
    // MARK: - Steam UI + /__eval

    func handleUIRequest(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "POST" {
            guard request.path == "/__eval" else { return .error(404, "Not Found") }
            let expr = String(data: request.body, encoding: .utf8) ?? ""
            let result = await evaluateInPage(expr)
            let body = #"{"ok":\#(result.ok),"v":\#(Self.jsonText(result.v) ?? "null")}"#
            return .ok(Data(body.utf8), type: "application/json")
        }
        guard request.method == "GET" else { return .error(405, "Method Not Allowed") }
        if request.path == "/" || request.path == "/index.html" {
            if !request.query.contains("IN_CLIENT") {
                // The bundle configures itself from location.search: without
                // IN_CLIENT=true every service call queues forever, and
                // without USE_POPUPS=true no window opens. Mirror the real
                // SharedJSContext's params verbatim.
                do {
                    return try await .redirect(to: "/index.html" + liveSearch())
                } catch {
                    return .error(503, "Steam client unreachable")
                }
            }
            return await injectedIndex()
        }
        return Self.serveFile(under: SteamBottle.steamui, path: request.path)
    }

    /// The real SharedJSContext's query string, fetched live because
    /// CLIENT_SESSION and the transport ports change on every client restart.
    /// SILENT_STARTUP stays, matching the client's `-silent` launch, so Steam's
    /// UI creates its desktop window hidden until `showSteam` shows it.
    private func liveSearch() async throws -> String {
        let cdp = try await ensureCDP()
        let search = try await withDeadline(ClientLifecycle.cdpCallCap) {
            try await cdp.evaluate("location.search")
        } ?? ""
        let kept = search.trimmingCharacters(in: CharacterSet(charactersIn: "?"))
            .components(separatedBy: "&")
            .filter { !$0.isEmpty }
        return "?" + kept.joined(separator: "&")
    }

    private func injectedIndex() async -> HTTPResponse {
        let indexURL = SteamBottle.steamui.appendingPathComponent("index.html")
        guard let html = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return .error(404, "steamui/index.html not found in the bottle")
        }
        // The shim mirrors the real client's shape: the UI feature-detects
        // Deck-only namespaces (System.Audio, …), so a Proxy answering every
        // property makes it call methods that do not exist.
        var shape = "{}"
        if let cdp = try? await ensureCDP(),
           let snapshot = try? await withDeadline(ClientLifecycle.cdpCallCap, { try await cdp.evaluate(BridgeJS.shape) }) {
            shape = snapshot
        }
        let injected = "<head>"
            + "<script>window.__sevoShape=\(shape);</script>"
            + "<script>\(shim)</script>"
            + StreamerMask.headTag(for: .current)
        guard let range = html.range(of: "<head>") else {
            return .error(500, "index.html has no <head>")
        }
        let body = html.replacingCharacters(in: range, with: injected)
        auditChromiumSurface()
        // A cached copy of this document would pin an old shim.
        return .ok(
            Data(body.utf8),
            type: "text/html; charset=utf-8",
            headers: [("Cache-Control", "no-store")],
        )
    }

    /// Logs each unguarded call to a Chromium-only API the shim does not
    /// supply, once per Steam UI bundle version.
    private func auditChromiumSurface() {
        let bundle = SteamBottle.steamui
        let main = bundle.appendingPathComponent("sp.js")
        let attributes = try? FileManager.default.attributesOfItem(atPath: main.path)
        let version = [
            (attributes?[.modificationDate] as? Date).map { String($0.timeIntervalSince1970) } ?? "",
            (attributes?[.size] as? NSNumber)?.stringValue ?? "",
        ].joined(separator: "/")
        guard version != auditedBundleVersion else { return }
        auditedBundleVersion = version
        Task(name: "Chromium surface audit", priority: .utility) { @concurrent [weak self] in
            let findings = ChromiumSurface.audit(bundle: bundle)
            if findings.isEmpty {
                self?.log(.bridge, "Steam UI \(version): every Chromium-only call is guarded or supplied")
            }
            for finding in findings {
                self?.log(.bridge, ChromiumSurface.sentence(for: finding))
            }
        }
    }

    // MARK: - Mac compatibility

    /// `GET /__compat/<appid>?name=<display name>&deck=<category>`: the
    /// community databases' verdicts for one game (``SteamCompatBadge``).
    /// The page supplies name and Deck category, which the client holds.
    nonisolated static func handleCompatRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let id = String(request.path.dropFirst("/__compat/".count)).prefix(while: { $0 != "." })
        guard let appID = Int(id) else { return .error(404, "Not Found") }
        let items = URLComponents(string: "http://127.0.0.1" + request.target)?.queryItems ?? []
        let name = items.first { $0.name == "name" }?.value ?? ""
        let deck = items.first { $0.name == "deck" }?.value.flatMap(Int.init)
        let body = await GameCompatService.shared.recordJSON(appID: appID, name: name, deckCategory: deck)
        return .ok(body, type: "application/json", headers: [("Cache-Control", "no-store")])
    }

    /// `POST /__compat/batch` with `{"apps": [[appid, "name"], …]}`: compact
    /// verdicts for the whole library
    /// (``GameCompatBatch/answer(_:pending:macBuilds:)``, ``SteamLibraryCompat``).
    nonisolated static func handleCompatBatchRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let games = GameCompatBatch.games(fromRequest: request.body)
        let (summaries, pending) = await GameCompatService.shared.summaries(for: games)
        let mapped = Engine.running.supportsSteamPlayMacOS ? SteamPlayMacOS.mappedApps() : []
        return .ok(
            GameCompatBatch.answer(summaries, pending: pending, macBuilds: mapped),
            type: "application/json", headers: [("Cache-Control", "no-store")],
        )
    }

    /// How long the native-build answer waits for the compatibility record
    /// (usually on disk already); past this the hints read as unrated.
    private static let nativeRecordPatience: Duration = .seconds(3)

    /// `GET /__native/<appid>?name=<display name>`: ``NativeBuildInfo`` for
    /// the game page (``SteamNativeBuilds``).
    nonisolated static func handleNativeBuildRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let id = String(request.path.dropFirst("/__native/".count)).prefix(while: { $0 != "." })
        guard let appID = Int(id) else { return .error(404, "Not Found") }
        let items = URLComponents(string: "http://127.0.0.1" + request.target)?.queryItems ?? []
        let name = items.first { $0.name == "name" }?.value ?? ""
        let record = try? await withDeadline(nativeRecordPatience) {
            await GameCompatService.shared.record(appID: appID, name: name, deckCategory: nil)
        }
        let appInfo = (try? Data(contentsOf: SteamAppInfo.fileURL, options: .alwaysMapped))
            .flatMap { SteamAppInfo.keyValues(appID: appID, in: $0) }
        let info = NativeBuildInfo.make(
            appID: appID, enabled: Engine.running.supportsSteamPlayMacOS, appInfo: appInfo,
            manifest: NativeBuildInfo.manifest(appID: appID), record: record,
            steamForMacCopy: SteamForMacCopy.offer(appID: appID),
        )
        let body = (try? JSONEncoder().encode(info)) ?? Data("{}".utf8)
        return .ok(body, type: "application/json", headers: [("Cache-Control", "no-store")])
    }

    // MARK: - Steam's web properties

    /// `GET /__web?u=<absolute URL>` (``WebProxy``).
    func handleWebRequest(_ request: HTTPRequest) async -> HTTPResponse {
        switch WebProxy.target(method: request.method, query: request.query) {
        case let .failure(rejection):
            log(.bridge, "web proxy refused a request: \(rejection.reason)")
            return .error(rejection.status, rejection.reason)
        case let .success(url):
            let cookies = await clientCookies() ?? []
            return await WebProxy.fetch(url, method: request.method, cookies: cookies)
        }
    }

    // MARK: - The client's own origin

    /// `GET /__loopback/<path>`: static assets from the Steam install, and
    /// the paths CEF synthesizes fetched from inside the client.
    func handleLoopbackRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return .error(405, "Method \(request.method) Not Allowed")
        }
        let path = LoopbackAssets.unprefixed(String(request.path.dropFirst(LoopbackAssets.pathPrefix.count)))
        if LoopbackAssets.isClientSynthesized(path) {
            let target = request.query.isEmpty ? path : path + "?" + request.query
            return await fetchFromClient(target)
        }
        guard LoopbackAssets.isServable(path) else {
            noteLoopbackMiss(path, "the Steam install's private files are not served")
            return .error(404, "Not Found")
        }
        let response = Self.serveFile(under: SteamBottle.steamRoot, path: path)
        if response.status == 404 { noteLoopbackMiss(path, "no file in the Steam install") }
        return response
    }

    /// One synthetic client path, fetched inside SharedJSContext and handed
    /// back as bytes: the client answers these from memory.
    private func fetchFromClient(_ target: String) async -> HTTPResponse {
        guard let cdp = try? await ensureCDP() else {
            noteLoopbackMiss(target, "the client is not reachable")
            return .error(503, "Client Unreachable")
        }
        let expression = """
        (async () => {
          try {
            const r = await fetch(\(JSLiteral.string(target)));
            if (!r.ok) return "";
            const b = await r.blob();
            if (b.size > \(Self.clientAssetCap(for: target))) return "";
            return await new Promise(done => {
              const reader = new FileReader();
              reader.onload = () => done(String(reader.result));
              reader.onerror = () => done("");
              reader.readAsDataURL(b);
            });
          } catch (e) { return ""; }
        })()
        """
        let reply = try? await withDeadline(.seconds(10)) {
            try await cdp.evaluate(expression)
        }
        guard let reply, let asset = Self.decodeDataURL(reply) else {
            noteLoopbackMiss(target, "the client returned nothing")
            return .error(404, "Not Found")
        }
        return .ok(asset.body, type: asset.type, headers: [("Cache-Control", "no-store")])
    }

    /// The largest asset read back out of the client, since a data URL
    /// crosses CDP as one JSON string; larger ones (a recording's video
    /// segments) take a logged 404. A full-resolution screenshot gets 32 MB,
    /// ~43 MB as base64, inside CDPClient's 64 MB message.
    private static func clientAssetCap(for target: String) -> Int {
        target.hasPrefix("/screenshots/") ? 32 * 1024 * 1024 : 4 * 1024 * 1024
    }

    private nonisolated static func decodeDataURL(_ text: String) -> (type: String, body: Data)? {
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: 5) ..< comma]
        guard header.hasSuffix(";base64") else { return nil }
        let type = String(header.dropLast(";base64".count))
        guard let body = Data(base64Encoded: String(text[text.index(after: comma)...])),
              !body.isEmpty else { return nil }
        return (type.isEmpty ? "application/octet-stream" : type, body)
    }

    /// Logs each loopback path the bridge could not answer, once, up to
    /// ``loopbackMissCap``.
    private func noteLoopbackMiss(_ path: String, _ why: String) {
        guard loopbackMisses.count < Self.loopbackMissCap,
              loopbackMisses.insert(path).inserted else { return }
        log(.bridge, "loopback \(path) went unanswered — \(why)")
    }

    private static let loopbackMissCap = 60

    // MARK: - Custom art

    /// Where Steam's UI asks for a game's custom art,
    /// `/customimages/<appid><suffix>.<ext>`, plus `<appid>.json` for the
    /// logo's placement.
    nonisolated static let customImagesPrefix = "/customimages/"

    /// `GET /customimages/<file>`, from the signed-in account's grid folder.
    nonisolated static func handleCustomImageRequest(_ request: HTTPRequest) -> HTTPResponse {
        guard let grid = SteamBottle.customArtwork else { return .error(404, "Not Found") }
        return serveFile(under: grid, path: String(request.path.dropFirst(customImagesPrefix.count)))
    }

    // MARK: - Art

    nonisolated static func handleArtRequest(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET", request.path.hasPrefix("/art/") else {
            return .error(404, "Not Found")
        }
        let appid = String(request.path.dropFirst("/art/".count))
            .prefix(while: { $0 != "." })
        guard !appid.isEmpty, appid.allSatisfy(\.isNumber) else {
            return .error(404, "Not Found")
        }
        if let data = cachedCapsule(appid: String(appid)) {
            return .ok(
                data,
                type: "image/jpeg",
                headers: [("Cache-Control", "max-age=86400")],
            )
        }
        return .redirect(to: "https://shared.steamstatic.com/store_item_assets/"
            + "steam/apps/\(appid)/library_600x900.jpg")
    }

    /// The vertical capsule's names; both hold the same 2:3 art and one
    /// library mixes them.
    private nonisolated static let capsuleNames = [
        "library_600x900.jpg", "library_capsule.jpg",
    ]

    /// The vertical capsule from the client's library cache, flat
    /// (`<appid>/<name>`) or content-addressed (`<appid>/<sha1>/<name>`). The
    /// CDN serves no capsule for age-gated titles, so a miss here is a blank
    /// tile for them.
    private nonisolated static func cachedCapsule(appid: String) -> Data? {
        let appDirectory = SteamBottle.libraryCache.appendingPathComponent(appid)
        for name in capsuleNames {
            let flat = appDirectory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: flat, options: [.mappedIfSafe]) { return data }
        }
        let contents = try? FileManager.default.contentsOfDirectory(
            at: appDirectory, includingPropertiesForKeys: [.isDirectoryKey],
        )
        for directory in contents ?? [] {
            for name in capsuleNames {
                let nested = directory.appendingPathComponent(name)
                if let data = try? Data(contentsOf: nested, options: [.mappedIfSafe]) {
                    return data
                }
            }
        }
        return nil
    }

    // MARK: - Files

    nonisolated static func serveFile(under root: URL, path: String) -> HTTPResponse {
        let serve = PerfProbe.bridge.beginInterval(
            "ServeAsset",
            id: PerfProbe.bridge.makeSignpostID(),
            "\(path, privacy: .public)",
        )
        defer { PerfProbe.bridge.endInterval("ServeAsset", serve) }
        guard let decoded = path.removingPercentEncoding else {
            return .error(400, "Bad Request")
        }
        let target = root.appendingPathComponent(decoded).standardizedFileURL
        guard target.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            return .error(403, "Forbidden")
        }
        let type = ContentType.forExtension(target.pathExtension)
        // A script or stylesheet that addresses the client's origin is served
        // from its cached rewritten copy (``LoopbackAssets``).
        if let rewritten = LoopbackAssets.rewrittenBytes(for: target) {
            return .ok(rewritten, type: type)
        }
        // Mapped: Steam's UI chunks run to megabytes and boot requests dozens.
        guard let data = try? Data(contentsOf: target, options: [.mappedIfSafe]) else {
            return .error(404, "Not Found")
        }
        return .ok(data, type: type)
    }
}
