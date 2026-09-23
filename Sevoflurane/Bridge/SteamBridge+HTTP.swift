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
                // IN_CLIENT=true its own WebSocket transport Init() bails
                // before SetDefaultTransport, every service call queues
                // forever, and without USE_POPUPS=true no window is ever
                // opened. Mirror the real SharedJSContext's params verbatim.
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

    /// The real SharedJSContext's query string (IN_CLIENT, USE_POPUPS,
    /// CLIENT_SESSION, …), fetched live because CLIENT_SESSION and the
    /// transport ports change on every client restart.
    ///
    /// SILENT_STARTUP is kept — the bottle client is launched with `-silent`
    /// and the page is told the same, so Steam's UI creates its desktop
    /// window Hidden and leaves it that way. This app is a menu-bar app: the
    /// window belongs on screen when someone asks for it, and `showSteam`
    /// routes and shows it then.
    private func liveSearch() async throws -> String {
        let cdp = try await ensureCDP()
        let search = try await cdp.evaluate("location.search") ?? ""
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
        // The shim must mirror the real client's shape: the desktop client
        // lacks whole namespaces the Deck has (System.Audio, …) and the UI
        // feature-detects them. A Proxy that answers every property makes the
        // UI call methods that do not exist.
        var shape = "{}"
        if let cdp = try? await ensureCDP(),
           let snapshot = try? await cdp.evaluate(BridgeJS.shape) {
            shape = snapshot
        }
        let injected = "<head>"
            + "<script>window.__sevoShape=\(shape);</script>"
            + "<script>\(shim)</script>"
        guard let range = html.range(of: "<head>") else {
            return .error(500, "index.html has no <head>")
        }
        let body = html.replacingCharacters(in: range, with: injected)
        // The shim is injected here and edited constantly; a cached copy of
        // this document silently pins an old one.
        return .ok(
            Data(body.utf8),
            type: "text/html; charset=utf-8",
            headers: [("Cache-Control", "no-store")],
        )
    }

    // MARK: - Mac compatibility

    /// `GET /__compat/<appid>?name=<display name>&deck=<category>`: the
    /// community databases' verdicts for one game, as the page's strip reads
    /// them (``SteamCompatBadge``). Name and Deck category come from the
    /// page because the client already holds both; the sources are keyed on
    /// the app id and, for the wiki, on the title.
    nonisolated static func handleCompatRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let id = String(request.path.dropFirst("/__compat/".count)).prefix(while: { $0 != "." })
        guard let appID = Int(id) else { return .error(404, "Not Found") }
        let items = URLComponents(string: "http://127.0.0.1" + request.target)?.queryItems ?? []
        let name = items.first { $0.name == "name" }?.value ?? ""
        let deck = items.first { $0.name == "deck" }?.value.flatMap(Int.init)
        let body = await GameCompatService.shared.recordJSON(appID: appID, name: name, deckCategory: deck)
        return .ok(body, type: "application/json", headers: [("Cache-Control", "no-store")])
    }

    // MARK: - Steam's web properties

    /// `GET /__web?u=<absolute URL>`: one Steam web page or document, fetched
    /// here so the page reads it same-origin. See ``WebProxy``.
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

    /// `GET /__loopback/<path>`: what the client's own origin used to serve.
    /// Static assets come out of the Steam install; the paths CEF synthesizes
    /// exist only inside the client, so they are fetched there.
    func handleLoopbackRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return .error(405, "Method \(request.method) Not Allowed")
        }
        let path = String(request.path.dropFirst(LoopbackAssets.pathPrefix.count))
        if LoopbackAssets.clientSynthesized.contains(where: path.hasPrefix) {
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

    /// One synthetic client path, read inside SharedJSContext and handed back
    /// as bytes. The client answers these from memory — a window's icon, an
    /// overlay's thumbnail, a recording's timeline — so there is nothing on
    /// disk to serve and no second origin to fetch them from.
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
            if (b.size > \(Self.clientAssetCap)) return "";
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

    /// The largest asset read back out of the client. A data URL crosses CDP
    /// as one JSON string, so a recording's video segments land well over it
    /// and take the logged 404 — which is the point: the log then names what a
    /// playtest actually asked for.
    private static let clientAssetCap = 4 * 1024 * 1024

    private nonisolated static func decodeDataURL(_ text: String) -> (type: String, body: Data)? {
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: 5) ..< comma]
        guard header.hasSuffix(";base64") else { return nil }
        let type = String(header.dropLast(";base64".count))
        guard let body = Data(base64Encoded: String(text[text.index(after: comma)...])),
              !body.isEmpty else { return nil }
        return (type.isEmpty ? "application/octet-stream" : type, body)
    }

    /// Names each loopback path the bridge could not answer, once. The set of
    /// endpoints Steam's UI reaches for is only observable by watching it run,
    /// and a repeat of the same miss says nothing the first line did not.
    private func noteLoopbackMiss(_ path: String, _ why: String) {
        guard loopbackMisses.count < Self.loopbackMissCap,
              loopbackMisses.insert(path).inserted else { return }
        log(.bridge, "loopback \(path) went unanswered — \(why)")
    }

    private static let loopbackMissCap = 60

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

    /// The names the vertical capsule is written under: clients write either
    /// `library_600x900.jpg` or `library_capsule.jpg`. Both hold the same 2:3
    /// art and one library mixes them freely.
    private nonisolated static let capsuleNames = [
        "library_600x900.jpg", "library_capsule.jpg",
    ]

    /// The vertical capsule from the client's own library cache.
    ///
    /// Two layouts coexist: the flat `<appid>/<name>` older clients wrote, and
    /// the content-addressed `<appid>/<sha1>/<name>` current ones write. The
    /// asset keeps its name inside the hash directory, so one level of
    /// enumeration finds it without a name→asset index. Both ``capsuleNames``
    /// are tried in each layout. Worth the lookup because the CDN serves no
    /// capsule at all for age-gated titles — an adult game shows a blank tile
    /// if this misses.
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
        // A script or stylesheet that addresses the client's own origin is
        // served from its rewritten copy (``LoopbackAssets``); the copy is
        // cached, so this costs one read of the source per Steam update.
        if let rewritten = LoopbackAssets.rewrittenBytes(for: target) {
            return .ok(rewritten, type: type)
        }
        // Mapped, not copied: Steam's UI chunks run to megabytes and the boot
        // waterfall requests dozens of them; the bytes go straight from the
        // page cache to the socket.
        guard let data = try? Data(contentsOf: target, options: [.mappedIfSafe]) else {
            return .error(404, "Not Found")
        }
        return .ok(data, type: type)
    }
}
