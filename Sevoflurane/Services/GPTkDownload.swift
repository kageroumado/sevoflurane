import Foundation
import Observation
import WebKit

/// Drives the download of Apple's D3DMetal: Apple's page hosted here, or the
/// user's own browser with ``GPTkFolderWatch`` waiting for the file.
///
/// D3DMetal lives in the "Evaluation environment for Windows games" disk
/// image; the larger "Game Porting Toolkit" image carries it inside, and
/// either installs. `download.developer.apple.com` serves only an
/// authenticated developer session, where each user accepts Apple's license,
/// so the user signs in to a free account in a `WKWebView` and the download
/// delegate catches and installs each DMG. Nothing is redistributed.
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

    /// Which route the panel shows.
    enum Route: Hashable {
        /// Apple's page, signed in inside this app.
        case here
        /// The user's own browser, with the download folders watched.
        case browser
    }

    var route = Route.here {
        didSet { syncFolderWatch() }
    }

    let folderWatch = GPTkFolderWatch()
    /// Whether Apple's page is loaded here. A simulated run loads nothing:
    /// the live page asks for real credentials.
    let loadsApplePage: Bool
    /// The host of the page the web view is on, so its owner can show whose
    /// page is asking for a password.
    private(set) var pageHost: String?

    private(set) var items: [Item] = []
    /// Whether the web view has finished its first load, so the panel can show
    /// a spinner until Apple's page is up.
    private(set) var pageLoaded = false

    /// Installs a downloaded DMG and answers a failure string, or `nil` on
    /// success.
    private let install: @MainActor (URL, D3DMetalInstaller.Origin) async -> String?
    /// Called with each version as it finishes installing.
    var onInstalled: (@MainActor (String) -> Void)?

    init(
        install: @escaping @MainActor (URL, D3DMetalInstaller.Origin) async -> String?,
        loadsApplePage: Bool = true,
    ) {
        self.install = install
        self.loadsApplePage = loadsApplePage
        super.init()
        folderWatch.onFound = { [weak self] url in self?.installLocal(url, found: true) }
    }

    /// Whether a view shows Apple's page, or in the gallery its stand-in.
    var showsApplePage: Bool {
        #if DEBUG
            if isStaged { return true }
        #endif
        return loadsApplePage
    }

    /// Whether a view of this download is on screen. The folders are read
    /// only while one is, on the browser route, in a run that is real.
    var isOnScreen = false {
        didSet { syncFolderWatch() }
    }

    private func syncFolderWatch() {
        #if DEBUG
            // A staged download reads as watching already and reads no folder.
            if isStaged { return }
        #endif
        if isOnScreen, route == .browser, loadsApplePage {
            folderWatch.start()
        } else {
            folderWatch.stop()
        }
    }

    /// Installs a disk image already on this Mac and leaves the file in place.
    /// A found image whose version is installed or on its way is skipped, so
    /// both of Apple's images for one version install once; a chosen file
    /// always installs.
    func installLocal(_ url: URL, found: Bool = false) {
        let filename = url.lastPathComponent
        if found, let version = Self.version(inFilename: filename) {
            let installed = D3DMetalInstaller.installed(inEngine: D3DMetalInstaller.store).map(\.version)
            let pending = items.filter { !$0.phase.isFailure }
                .compactMap { Self.version(inFilename: $0.filename) }
            guard !installed.contains(version), !pending.contains(version) else { return }
        }
        nextID += 1
        let id = nextID
        items.append(Item(id: id, filename: filename, fraction: 1, phase: .installing))
        Task { await finishInstall(id: id, from: url, origin: found ? .foundInFolder : .chosen) }
    }

    var isBusy: Bool {
        items.contains { $0.phase == .downloading || $0.phase == .installing }
    }

    /// Where the automatic pick-and-download stands, for the panel's overlay.
    /// `manual`, the fallback when nothing parseable stabilized, is the one
    /// phase that shows Apple's page itself.
    enum AutoPhase {
        case idle
        case searching
        case downloading
        case manual
    }

    private(set) var autoPhase: AutoPhase = .idle
    /// The versions the automatic pick chose, in the order it chose them:
    /// "4.0", "4.0 beta 2".
    private(set) var pickedVersions: [String] = []
    /// The row the manual fallback outlined on Apple's page, as the page
    /// names it: "Evaluation environment for Windows games 4.0 beta 2".
    private(set) var manualCandidate: String?
    /// Whether a link toward the paid Developer Program was stopped.
    private(set) var stoppedEnrollment = false

    /// Uncovers Apple's page after an automatic download failed.
    func showPage() {
        autoPhase = .manual
    }

    #if DEBUG
        /// Whether the gallery staged this download: its page is then a
        /// stand-in that loads nothing, and no folder is read.
        @ObservationIgnored private(set) var isStaged = false

        /// Puts the download where the gallery draws it, with Apple's page
        /// counted as loaded and, on the browser route, the folders as watched.
        func stage(
            route: Route = .here, autoPhase: AutoPhase = .idle, items: [Item] = [],
            pickedVersions: [String] = [], manualCandidate: String? = nil, stoppedEnrollment: Bool = false,
        ) {
            isStaged = true
            pageLoaded = true
            pageHost = Self.pageURL.host()
            self.route = route
            self.autoPhase = autoPhase
            self.items = items
            self.pickedVersions = pickedVersions
            self.manualCandidate = manualCandidate
            self.stoppedEnrollment = stoppedEnrollment
            if route == .browser { folderWatch.stageWatching() }
        }
    #endif

    private var nextID = 0
    private var startedDownloads: Set<String> = []
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var itemIDs: [ObjectIdentifier: Int] = [:]
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    @ObservationIgnored private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Reports the toolkit links once Apple's authenticated list renders;
        // `decideDestinationUsing` refuses a second copy of a file.
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
    /// which downloads them directly: two links clicked in one tick let the
    /// second navigation cancel the first. Versions parse from the filename
    /// segment only (a row's path can say 1.1 while its file is 2.1), and
    /// picks wait until the parsed set has been stable for three seconds,
    /// since the list renders incrementally.
    ///
    /// "list" fires when the signed-in table first exists; "none" when it
    /// stabilizes with nothing parseable, outlining the row that names the
    /// newest version and sending its name as `candidate`.
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
      const evaluation = (c) =>
        (decodeURIComponent(c.href).split("/").pop() || "").toLowerCase().startsWith("evaluation");
      // Of two images for one version, the evaluation environment: it is the
      // one D3DMetal is in, a quarter the size of the toolkit that wraps it.
      const prefer = (a, b) => a.key === b.key && evaluation(a) && !evaluation(b);
      const newer = (a, b) => {
        const len = Math.max(a.version.length, b.version.length);
        for (let i = 0; i < len; i += 1) {
          const x = a.version[i] || 0;
          const y = b.version[i] || 0;
          if (x !== y) { return x > y; }
        }
        // A release follows its own betas: 4.0 is newer than 4.0 beta 2.
        const rank = (c) => (c.beta === null ? Infinity : c.beta);
        return rank(a) > rank(b);
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
            if (!release || newer(c, release) || prefer(c, release)) { release = c; }
          } else if (!beta || newer(c, beta) || prefer(c, beta)) {
            beta = c;
          }
        }
        if (beta && release && !newer(beta, release)) { beta = null; }
        return [release, beta].filter(Boolean);
      };
      const rowPattern =
        /(evaluation environment for windows games|game porting toolkit)\\s*(\\d+(?:\\.\\d+)*)(?:\\s*beta\\s*(\\d+))?/i;
      const ranksAbove = (a, b) => {
        const len = Math.max(a.version.length, b.version.length);
        for (let i = 0; i < len; i += 1) {
          const x = a.version[i] || 0;
          const y = b.version[i] || 0;
          if (x !== y) { return x > y; }
        }
        if ((a.beta === null) !== (b.beta === null)) { return a.beta === null; }
        if (a.beta !== b.beta) { return a.beta > b.beta; }
        return a.evaluation && !b.evaluation;
      };
      // The deepest element whose text names a toolkit row: its text may be
      // split over several nodes, so whole elements are matched.
      const outlineBestRow = () => {
        let best = null;
        for (const element of document.body.querySelectorAll("*")) {
          const text = element.textContent || "";
          if (text.length > 200) { continue; }
          const m = text.match(rowPattern);
          if (!m) { continue; }
          if (Array.from(element.children).some((child) => rowPattern.test(child.textContent || ""))) {
            continue;
          }
          const candidate = {
            element,
            name: m[0].replace(/\\s+/g, " ").trim(),
            evaluation: m[1].toLowerCase().startsWith("evaluation"),
            version: m[2].split(".").map(Number),
            beta: m[3] ? Number(m[3]) : null,
          };
          if (!best || ranksAbove(candidate, best)) { best = candidate; }
        }
        if (!best) { return null; }
        best.element.style.outline = "3px solid #ff9f0a";
        best.element.style.outlineOffset = "4px";
        best.element.style.borderRadius = "6px";
        best.element.scrollIntoView({ block: "center", behavior: "smooth" });
        return best.name;
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
            post({ type: "none", candidate: outlineBestRow() });
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

    /// Whether a URL leads into the paid Apple Developer Program's
    /// enrollment, which the toolkit download never needs: a developer.apple.com
    /// page with an `enroll` or `enrollment` segment in its path or fragment
    /// (`/programs/enroll/`, `/enroll/app`, `/account/#/enroll`).
    nonisolated static func isEnrollment(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(),
              host == "developer.apple.com" || host.hasSuffix(".developer.apple.com") else { return false }
        let fragment = url.fragment(percentEncoded: false)?.split(separator: "/").map(String.init) ?? []
        return (url.pathComponents + fragment).contains { segment in
            ["enroll", "enrollment"].contains(segment.lowercased())
        }
    }

    /// The versions a pick's download links name, in order, each once.
    nonisolated static func versions(inLinks links: [String]) -> [String] {
        var versions: [String] = []
        for link in links {
            guard let url = URL(string: link),
                  let version = version(inFilename: url.lastPathComponent),
                  !versions.contains(version) else { continue }
            versions.append(version)
        }
        return versions
    }

    /// Whether a URL is one of Apple's authenticated developer downloads, the
    /// only place a toolkit is fetched from.
    nonisolated static func isAppleDownload(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host()?.lowercased() == "download.developer.apple.com"
            && url.user == nil && url.password == nil
    }

    /// The version a toolkit DMG's filename names, as Apple writes it:
    /// "Evaluation_environment_for_Windows_games_4.0_beta_2.dmg" → "4.0 beta 2".
    nonisolated static func version(inFilename filename: String) -> String? {
        guard let range = filename.range(
            of: #"[0-9]+\.[0-9]+(?:[ _]beta[ _][0-9]+)?"#, options: .regularExpression,
        ) else { return nil }
        return filename[range].replacingOccurrences(of: "_", with: " ")
    }

    /// Whether a downloaded file looks like a toolkit DMG rather than some
    /// other file the user might grab from the developer site.
    nonisolated static func isToolkitDMG(_ filename: String) -> Bool {
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
        // The web view follows links anywhere, and the script runs on every
        // page it lands on; only Apple's own page speaks for the downloads.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == Self.pageURL.host(),
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "list":
            if autoPhase == .idle { autoPhase = .searching }
        case "none":
            manualCandidate = body["candidate"] as? String
            if autoPhase == .searching { autoPhase = .manual }
        case "picks":
            guard let urls = body["urls"] as? [String] else { return }
            let apple = urls.filter { URL(string: $0).map(Self.isAppleDownload) ?? false }
            for version in Self.versions(inLinks: apple) where !pickedVersions.contains(version) {
                pickedVersions.append(version)
            }
            stoppedEnrollment = false
            for raw in urls where !startedDownloads.contains(raw) {
                guard let url = URL(string: raw), Self.isAppleDownload(url) else { continue }
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
    /// A link into the paid program's enrollment is stopped, and Apple's
    /// download page is loaded in its place with a note saying the free
    /// account is enough.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url, Self.isEnrollment(url) else { return .allow }
        EventLog.shared.log(.setup, "D3DMetal download: stopped a link to \(url.path()), the paid program")
        stoppedEnrollment = true
        // Once the cancellation has gone through, so the two navigations
        // never race.
        DispatchQueue.main.async { webView.load(URLRequest(url: Self.pageURL)) }
        return .cancel
    }

    func webView(
        _: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    ) async -> WKNavigationResponsePolicy {
        // A DMG is not something the web view can display, so it becomes a
        // download. Apple's own auth redirects render inline and stay in the
        // page.
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        pageLoaded = true
        notePageHost(of: webView)
    }

    func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        notePageHost(of: webView)
    }

    private func notePageHost(of webView: WKWebView) {
        let host = webView.url?.host()
        if host != pageHost { pageHost = host }
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
        guard Self.isToolkitDMG(suggestedFilename),
              let url = download.originalRequest?.url, Self.isAppleDownload(url) else {
            // Not a toolkit from Apple: the download is cancelled.
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
            await finishInstall(id: id, from: source)
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
        }
    }

    private func finishInstall(id: Int, from source: URL, origin: D3DMetalInstaller.Origin = .chosen) async {
        let failure = await install(source, origin)
        if let failure {
            updatePhase(id: id, .failed(failure))
        } else if let version = Self.version(inFilename: source.lastPathComponent) {
            updatePhase(id: id, .installed(version: version))
            onInstalled?(version)
        } else {
            updatePhase(id: id, .installed(version: source.lastPathComponent))
        }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData _: Data?) {
        let key = ObjectIdentifier(download)
        observations.removeValue(forKey: key)?.invalidate()
        // The partial file's folder goes with the failure; a retry gets its own.
        if let destination = destinations.removeValue(forKey: key) {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }
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
}
