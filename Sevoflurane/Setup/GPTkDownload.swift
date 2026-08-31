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

    private var nextID = 0
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
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: Self.pageURL))
        return view
    }()

    /// Clicks the newest release and newest beta toolkit DMGs, so the user
    /// only has to finish Apple's sign-in. The list renders incrementally
    /// (oldest versions can land first — an eager sweep once grabbed 1.0),
    /// so picks happen only after the DOM has been quiet for a beat, and a
    /// beta older than the release is skipped. A MutationObserver rather
    /// than a load hook: the page's own scripts render the list well after
    /// `didFinish`, and again after the sign-in redirect.
    private static let autoDownloadScript = """
    (function () {
      if (window.__sevoGPTkAutoDownload) { return; }
      window.__sevoGPTkAutoDownload = true;
      const clicked = new Set();
      const parse = (href) => {
        const name = decodeURIComponent(href);
        const m = name.match(
          /game.{0,3}porting.{0,3}toolkit.{0,3}(\\d+(?:\\.\\d+)*)(?:.{0,3}beta.{0,3}(\\d+))?/i);
        if (!m) { return null; }
        return { version: m[1].split(".").map(Number), beta: m[2] ? Number(m[2]) : null };
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
      const pickAndClick = () => {
        let release = null;
        let beta = null;
        for (const link of document.querySelectorAll("a[href]")) {
          const href = link.href;
          if (!/\\.dmg(?:$|[?#])/i.test(href)) { continue; }
          const parsed = parse(href);
          if (!parsed) { continue; }
          const candidate = { link, href, ...parsed };
          if (candidate.beta === null) {
            if (!release || newer(candidate, release)) { release = candidate; }
          } else if (!beta || newer(candidate, beta)) {
            beta = candidate;
          }
        }
        if (beta && release && !newer(beta, release)) { beta = null; }
        for (const pick of [release, beta]) {
          if (!pick || clicked.has(pick.href)) { continue; }
          clicked.add(pick.href);
          pick.link.click();
        }
      };
      let settle = null;
      const arm = () => {
        if (settle) { clearTimeout(settle); }
        settle = setTimeout(pickAndClick, 1200);
      };
      new MutationObserver(arm)
        .observe(document.documentElement, { childList: true, subtree: true });
      arm();
    })();
    """

    /// Whether a downloaded file looks like a toolkit DMG rather than some
    /// other file the user might grab from the developer site.
    private static func isToolkitDMG(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".dmg")
            && lower.contains("porting")
            && lower.contains("game")
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
