import Foundation
import Observation
import WebKit

/// Drives an in-app download of Apple's Game Porting Toolkit.
///
/// The toolkit is behind Apple's own sign-in — `download.developer.apple.com`
/// refuses anyone without an authenticated developer session, and that
/// sign-in is where each user accepts Apple's license. So the flow is Apple's
/// own web flow, hosted in a `WKWebView`: the user signs in as themselves
/// (most Mac accounts already have an Apple ID; enrolling as a developer is
/// free and happens in the same window), the page serves them the release and
/// beta DMGs, and the download delegate here catches each one and installs it.
/// Nothing is hosted or redistributed by us; this only removes the round trip
/// to a browser and the `~/Downloads` hunt. The same pattern the Xcode version
/// managers use for Xcode itself, on the same Apple infrastructure.
@MainActor
@Observable
final class GPTkDownload: NSObject {
    /// One toolkit download in flight or finished.
    struct Item: Identifiable {
        let id: Int
        let filename: String
        var fraction: Double
        var phase: Phase

        enum Phase: Equatable {
            case downloading
            case installing
            case installed(version: String)
            case failed(String)

            var isFailure: Bool {
                if case .failed = self { true } else { false }
            }
        }
    }

    /// Apple's filtered download list — the release toolkit and any current
    /// beta both appear here.
    static let pageURL = URL(
        string: "https://developer.apple.com/download/all/?q=game%20porting%20toolkit",
    )!

    private(set) var items: [Item] = []
    /// Whether the web view has finished its first load, so the panel can show
    /// a spinner until Apple's page is up.
    private(set) var pageLoaded = false

    /// Installs a downloaded DMG and answers a failure string, or `nil` on
    /// success. Injected so this controller need not know about the engine —
    /// the panel wires it to `GraphicsStore.installD3DMetal`.
    var install: (@MainActor (URL) async -> String?)?
    /// Called with each version as it finishes installing.
    var onInstalled: (@MainActor (String) -> Void)?

    /// Versions installed this session, newest label last.
    var installedVersions: [String] {
        items.compactMap { if case let .installed(v) = $0.phase { v } else { nil } }
    }

    var isBusy: Bool {
        items.contains { $0.phase == .downloading || $0.phase == .installing }
    }

    /// Where the automatic pick-and-download stands, for the panel's
    /// overlay: `searching` covers the page from sign-in until versions are
    /// chosen; `manual` is the fallback when nothing parseable stabilized.
    enum AutoPhase {
        case idle
        case searching
        case downloading
        case manual
    }

    private(set) var autoPhase: AutoPhase = .idle

    private var nextID = 0
    private var startedDownloads: Set<String> = []
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var itemIDs: [ObjectIdentifier: Int] = [:]
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    @ObservationIgnored private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Sign-in is the flow's whole friction, so the moment the toolkit
        // links exist (Apple's list renders after load, and only once the
        // session is authenticated) they are clicked for the user. The
        // duplicate guard in `decideDestinationUsing` keeps a re-render's
        // re-click from downloading a file twice.
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.autoDownloadScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
        ))
        // Weakly, or the content controller's strong handler reference
        // cycles back through the web view.
        configuration.userContentController.add(WeakMessageHandler(self), name: "gptk")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: Self.pageURL))
        return view
    }()

    /// Reports the newest release and newest beta toolkit DMGs to Swift,
    /// which downloads them directly — clicking two links in one tick made
    /// the second navigation cancel the first before it could become a
    /// download (measured: only the last click's file arrived). Hard-won
    /// parsing rules, from the live anchor list: versions parse from the
    /// *filename* segment only (a row's path can say 1.1 while its file is
    /// 2.1); "Evaluation environment for Windows games" is the same product
    /// under Apple's alternate name; and the list renders incrementally (an
    /// eager sweep once grabbed 1.0, a debounced one 2.1), so picks wait
    /// until the parsed candidate set has been stable for three seconds.
    /// "list" fires when the signed-in download table first exists, "none"
    /// when it stabilizes with nothing parseable — the panel's overlay and
    /// fallback hint key off those.
    private static let autoDownloadScript = """
    (function () {
      if (window.__sevoGPTkAutoDownload) { return; }
      window.__sevoGPTkAutoDownload = true;
      const post = (message) => {
        try { window.webkit.messageHandlers.gptk.postMessage(message); } catch (e) {}
      };
      const parse = (href) => {
        const file = decodeURIComponent(href).split("/").pop() || "";
        const m = file.match(
          /^(?:game[_ ]?porting[_ ]?toolkit|evaluation[_ ]environment[_ ]for[_ ]windows[_ ]games)[_ ]*(\\d+(?:\\.\\d+)*)(?:[_ ]*beta[_ ]*(\\d+))?\\.dmg$/i);
        if (!m) { return null; }
        return {
          key: m[1] + (m[2] ? "b" + m[2] : ""),
          version: m[1].split(".").map(Number),
          beta: m[2] ? Number(m[2]) : null,
        };
      };
      const newer = (a, b) => {
        const len = Math.max(a.version.length, b.version.length);
        for (let i = 0; i < len; i += 1) {
          const x = a.version[i] || 0;
          const y = b.version[i] || 0;
          if (x !== y) { return x > y; }
        }
        return (a.beta || 0) > (b.beta || 0);
      };
      const scan = () => {
        const found = [];
        let listUp = false;
        for (const link of document.querySelectorAll("a[href]")) {
          if (link.href.includes("download.developer.apple.com")) { listUp = true; }
          const parsed = parse(link.href);
          if (parsed) { found.push({ href: link.href, ...parsed }); }
        }
        return { found, listUp };
      };
      const picks = (found) => {
        let release = null;
        let beta = null;
        for (const c of found) {
          if (c.beta === null) {
            if (!release || newer(c, release)) { release = c; }
          } else if (!beta || newer(c, beta)) {
            beta = c;
          }
        }
        if (beta && release && !newer(beta, release)) { beta = null; }
        return [release, beta].filter(Boolean);
      };
      let announcedList = false;
      let reportedKeys = "";
      let lastSignature = "";
      let stableSince = 0;
      setInterval(() => {
        const { found, listUp } = scan();
        if (listUp && !announcedList) {
          announcedList = true;
          post({ type: "list" });
        }
        if (!listUp) { return; }
        const signature = found.map((c) => c.key).sort().join(",");
        const now = Date.now();
        if (signature !== lastSignature) {
          lastSignature = signature;
          stableSince = now;
          return;
        }
        if (now - stableSince < 3000) { return; }
        if (found.length === 0) {
          if (reportedKeys !== "none") {
            reportedKeys = "none";
            post({ type: "none" });
          }
          return;
        }
        const chosen = picks(found);
        const keys = chosen.map((c) => c.key).sort().join(",");
        if (keys !== reportedKeys) {
          reportedKeys = keys;
          post({ type: "picks", urls: chosen.map((c) => c.href) });
        }
      }, 1000);
    })();
    """

    /// Whether a downloaded file looks like a toolkit DMG rather than some
    /// other file the user might grab from the developer site.
    private static func isToolkitDMG(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        guard lower.hasSuffix(".dmg") else { return false }
        // Apple serves the same product under both names — several rows'
        // DMGs are "Evaluation_environment_for_Windows_games_X.Y.dmg".
        return (lower.contains("game") && lower.contains("porting"))
            || (lower.contains("evaluation") && lower.contains("windows"))
    }
}

/// Breaks the retain cycle `GPTkDownload → WKWebView → userContentController
/// → handler`: the controller holds this proxy strongly, the target weakly.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
    ) {
        target?.userContentController(controller, didReceive: message)
    }
}

extension GPTkDownload: WKScriptMessageHandler {
    func userContentController(
        _: WKUserContentController, didReceive message: WKScriptMessage,
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "list":
            if autoPhase == .idle { autoPhase = .searching }
        case "none":
            if autoPhase == .searching { autoPhase = .manual }
        case "picks":
            guard let urls = body["urls"] as? [String] else { return }
            for raw in urls where !startedDownloads.contains(raw) {
                guard let url = URL(string: raw) else { continue }
                startedDownloads.insert(raw)
                webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
                    download.delegate = self
                }
            }
            if !urls.isEmpty { autoPhase = .downloading }
        default:
            break
        }
    }
}

extension GPTkDownload: WKNavigationDelegate {
    func webView(
        _: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    ) async -> WKNavigationResponsePolicy {
        // A DMG is not something the web view can display, so it becomes a
        // download. Apple's own auth redirects render inline and stay in the
        // page.
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        pageLoaded = true
    }

    func webView(
        _: WKWebView, navigationResponse _: WKNavigationResponse, didBecome download: WKDownload,
    ) {
        download.delegate = self
    }

    func webView(
        _: WKWebView, navigationAction _: WKNavigationAction, didBecome download: WKDownload,
    ) {
        download.delegate = self
    }
}

extension GPTkDownload: WKDownloadDelegate {
    func download(
        _ download: WKDownload, decideDestinationUsing _: URLResponse, suggestedFilename: String,
    ) async -> URL? {
        guard Self.isToolkitDMG(suggestedFilename) else {
            // Not a toolkit; let the browser's normal download take it to
            // ~/Downloads rather than pull it into our temp dir.
            return nil
        }
        guard !items.contains(where: {
            $0.filename == suggestedFilename && !$0.phase.isFailure
        }) else {
            // The auto-click and a manual click can both start the same
            // file; the second copy is refused here.
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sevo-gptk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(suggestedFilename)

        nextID += 1
        let id = nextID
        let key = ObjectIdentifier(download)
        destinations[key] = destination
        itemIDs[key] = id
        items.append(Item(id: id, filename: suggestedFilename, fraction: 0, phase: .downloading))
        observations[key] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.updateFraction(id: id, fraction: fraction) }
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        observations.removeValue(forKey: key)?.invalidate()
        guard let id = itemIDs[key], let source = destinations[key] else { return }
        updatePhase(id: id, .installing)
        Task {
            let failure = await install?(source)
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            if let failure {
                updatePhase(id: id, .failed(failure))
            } else if let version = installedVersion(matching: source.lastPathComponent) {
                updatePhase(id: id, .installed(version: version))
                onInstalled?(version)
            } else {
                updatePhase(id: id, .installed(version: source.lastPathComponent))
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData _: Data?) {
        let key = ObjectIdentifier(download)
        observations.removeValue(forKey: key)?.invalidate()
        if let id = itemIDs[key] {
            updatePhase(id: id, .failed(error.localizedDescription))
        }
    }

    private func updateFraction(id: Int, fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if case .downloading = items[index].phase { items[index].fraction = fraction }
    }

    private func updatePhase(id: Int, _ phase: Item.Phase) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = phase
    }

    /// The version string that would have come from the DMG's filename, so a
    /// finished item can name what it installed even before the store refreshes.
    private func installedVersion(matching filename: String) -> String? {
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = try? NSRegularExpression(
            pattern: #"[0-9]+\.[0-9]+( beta [0-9]+)?"#,
        ).firstMatch(in: filename, range: range),
            let matchRange = Range(match.range, in: filename) else { return nil }
        return String(filename[matchRange])
    }
}
