import AppKit
import os

extension SteamWebHost {
    /// What one profile run is asked to do. Parsed from the control
    /// endpoint's query string so the CLI and a curl invocation agree.
    nonisolated struct BenchmarkOptions: Sendable, Equatable {
        static let iterationRange = 1 ... 10

        var iterations = 5
        var target: String?
        /// Busy threads standing in for a game for the length of the run.
        var loadThreads = 0
        var loadQualityOfService: SyntheticLoad.QualityOfService = .default

        init() {}

        init(query: String) {
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let value = String(parts[1])
                switch parts[0] {
                case "iterations":
                    if let count = Int(value) {
                        iterations = min(max(count, Self.iterationRange.lowerBound), Self.iterationRange.upperBound)
                    }
                case "target":
                    target = value
                case "load":
                    loadThreads = max(0, Int(value) ?? 0)
                case "qos":
                    loadQualityOfService = SyntheticLoad.QualityOfService(rawValue: value) ?? .default
                default:
                    break
                }
            }
        }
    }

    /// One complete profile run, serialized because all three targets share
    /// Steam's desktop page and popup manager.
    struct BenchmarkReport: Encodable {
        let iterations: Int
        /// `visible`, `forced` (the window was covered, so occlusion
        /// detection was suspended for the run), or `hidden` (it stayed
        /// hidden — every step is then `skipped`).
        let desktopVisibility: String
        let load: BenchmarkLoad
        let hostBefore: HostSnapshot
        let hostAfter: HostSnapshot
        let samples: [BenchmarkSample]
        let summaries: [BenchmarkSummary]
    }

    struct BenchmarkLoad: Encodable {
        let threads: Int
        let qualityOfService: String
    }

    struct BenchmarkSample: Encodable {
        let iteration: Int
        let target: String
        let milliseconds: Double
        /// `ready`, `failed`, or `skipped`.
        let outcome: String
        let detail: String?
        /// The main thread's queueing delays while this step ran.
        let mainThread: MainQueueLatencyProbe.Snapshot
    }

    struct BenchmarkSummary: Encodable {
        let target: String
        let successfulSamples: Int
        let totalSamples: Int
        let p50Milliseconds: Double?
        let p95Milliseconds: Double?
        let maxMainThreadDelayMilliseconds: Double
    }

    enum BenchmarkFailure: LocalizedError {
        case alreadyRunning
        case desktopUnavailable
        case desktopHidden(String)
        case invalidTarget(String)
        case commandRejected(String)
        case readinessTimedOut(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "a benchmark is already running"
            case .desktopUnavailable: "Steam desktop did not become visible"
            case let .desktopHidden(state): "desktop page is \(state) to WebKit — nothing renders"
            case let .invalidTarget(target): "unknown benchmark target: \(target)"
            case let .commandRejected(reply): "Steam rejected the command: \(reply)"
            case let .readinessTimedOut(signal): "timed out waiting for \(signal)"
            }
        }
    }

    private enum BenchmarkTarget: String, CaseIterable {
        case library
        case store
        case friends
    }

    /// Runs a repeatable, warm UI workload. It does not use DOM selectors:
    /// Library waits for two desktop frames, Store also waits for its native
    /// BrowserView to settle, and Friends waits for its adopted NSWindow.
    func runSmokeBenchmark(options: BenchmarkOptions) async throws -> BenchmarkReport {
        guard !benchmarkRunning else { throw BenchmarkFailure.alreadyRunning }
        benchmarkRunning = true
        defer { benchmarkRunning = false }

        let iterations = options.iterations
        let targets = try Self.benchmarkTargets(named: options.target)
        let run = PerfProbe.benchmark.beginInterval(
            "SmokeScenario", id: PerfProbe.benchmark.makeSignpostID(),
            "load=\(options.loadThreads, privacy: .public)",
        )
        defer {
            PerfProbe.benchmark.endInterval(
                "SmokeScenario", run,
                "iterations=\(iterations),targets=\(targets.map(\.rawValue).joined(separator: ","))",
            )
        }

        let hostBefore = HostSnapshot.take()
        showSteam()
        try await waitForDesktopVisibility()
        try await waitForPageReady()
        let visibility = await ensureDesktopPageVisible()
        defer { desktop?.suspendOcclusionDetection(false) }

        let load = SyntheticLoad(
            threads: options.loadThreads, qualityOfService: options.loadQualityOfService,
        )
        load.start()
        defer { load.stop() }
        mainQueueLatency.start()
        defer { mainQueueLatency.stop() }
        // Let the load and the watchdog reach steady state before timing.
        try await Task.sleep(for: .milliseconds(500))
        _ = mainQueueLatency.snapshotAndReset()

        let samples = try await benchmarkSamples(
            of: targets, iterations: iterations, desktopVisibility: visibility,
        )
        load.stop()
        return BenchmarkReport(
            iterations: iterations,
            desktopVisibility: visibility,
            load: BenchmarkLoad(
                threads: load.threadCount,
                qualityOfService: options.loadQualityOfService.rawValue,
            ),
            hostBefore: hostBefore,
            hostAfter: HostSnapshot.take(),
            samples: samples,
            summaries: targets.map { summary(for: $0, in: samples) },
        )
    }

    /// The targets a run covers: the one it names, or every one.
    private static func benchmarkTargets(named requestedTarget: String?) throws -> [BenchmarkTarget] {
        guard let requestedTarget else { return BenchmarkTarget.allCases }
        guard let target = BenchmarkTarget(rawValue: requestedTarget) else {
            throw BenchmarkFailure.invalidTarget(requestedTarget)
        }
        return [target]
    }

    /// One sample per target per iteration. A hidden desktop page yields
    /// skipped samples, since nothing measured on it would ever complete.
    private func benchmarkSamples(
        of targets: [BenchmarkTarget], iterations: Int, desktopVisibility visibility: String,
    ) async throws -> [BenchmarkSample] {
        var samples: [BenchmarkSample] = []
        for iteration in 1 ... iterations {
            try Task.checkCancellation()
            for target in targets {
                if visibility == "hidden" {
                    samples.append(skippedSample(target: target, iteration: iteration))
                    continue
                }
                try await samples.append(benchmark(target: target, iteration: iteration))
            }
        }
        return samples
    }

    /// The desktop page as WebKit sees it. A covered window is `hidden` —
    /// animation frames stop and nothing measured below would ever complete
    /// — so occlusion detection is suspended for the run and the page
    /// re-read; `forced` means that was needed. A page still hidden after
    /// that is not on any screen, and the run reports it instead of timing it.
    private func ensureDesktopPageVisible() async -> String {
        guard let desktop else { return "hidden" }
        if await desktopPageVisibilityState(desktop) == "visible" { return "visible" }
        desktop.suspendOcclusionDetection(true)
        for _ in 0 ..< 20 {
            try? await Task.sleep(for: .milliseconds(100))
            if await desktopPageVisibilityState(desktop) == "visible" { return "forced" }
        }
        return "hidden"
    }

    private func desktopPageVisibilityState(_ desktop: SteamWindow) async -> String {
        await evaluateInWebView("String(document.visibilityState)", webView: desktop.webView) ?? "unknown"
    }

    private func skippedSample(target: BenchmarkTarget, iteration: Int) -> BenchmarkSample {
        BenchmarkSample(
            iteration: iteration, target: target.rawValue, milliseconds: 0,
            outcome: "skipped", detail: BenchmarkFailure.desktopHidden("hidden").errorDescription,
            mainThread: mainQueueLatency.snapshotAndReset(),
        )
    }

    private func benchmark(target: BenchmarkTarget, iteration: Int) async throws -> BenchmarkSample {
        switch target {
        case .library: try await benchmarkLibrary(iteration: iteration)
        case .store: try await benchmarkStore(iteration: iteration)
        case .friends: try await benchmarkFriends(iteration: iteration)
        }
    }

    private func benchmarkLibrary(iteration: Int) async throws -> BenchmarkSample {
        try await benchmarkStep(target: .library, iteration: iteration) {
            let reply = await self.evaluateInContext(Self.libraryBenchmarkScript)
            try self.requireBenchmarkCommand(reply)
            try await self.waitForDesktopFrame()
        }
    }

    private func benchmarkStore(iteration: Int) async throws -> BenchmarkSample {
        try await benchmarkStep(target: .store, iteration: iteration) {
            let reply = await self.evaluateInContext(Self.storeBenchmarkScript)
            try self.requireBenchmarkCommand(reply)
            // Store readiness belongs to the native BrowserView child. Its
            // load state remains reliable when Steam throttles Desktop rAFs.
            try await self.waitForStoreBrowserView()
        }
    }

    private func benchmarkFriends(iteration: Int) async throws -> BenchmarkSample {
        // An open Friends window would make the step trivially ready; close
        // it first so the sample is a real open, popup creation included.
        if friendsWindow != nil {
            do {
                try await closeFriendsFromSteam()
            } catch let failure as BenchmarkFailure {
                return BenchmarkSample(
                    iteration: iteration, target: BenchmarkTarget.friends.rawValue, milliseconds: 0,
                    outcome: "failed", detail: "before the step: \(failure.localizedDescription)",
                    mainThread: mainQueueLatency.snapshotAndReset(),
                )
            }
        }
        return try await benchmarkStep(target: .friends, iteration: iteration) {
            let reply = await self.evaluateInContext(Self.friendsBenchmarkScript)
            try self.requireBenchmarkCommand(reply)
            try await self.waitForFriendsWindow()
        }
    }

    private var friendsWindow: SteamWindow? {
        popups.values.first { $0.role == .friends }
    }

    /// Closes the Friends popup the way its close button does: from Steam's
    /// side, so the popup manager drops its record before our window goes.
    /// Closing our window first (`SteamWindow.close()`) races the page's own
    /// teardown, and Steam then keeps a record of a dead popup against which
    /// every later show request is a no-op.
    private func closeFriendsFromSteam() async throws {
        _ = await evaluateInContext(Self.friendsCloseScript)
        try await waitForReadiness("Steam to drop the Friends popup") { [weak self] in
            await self?.evaluateInContext(Self.friendsPopupGoneScript) == "true"
        }
        try await waitForReadiness("Friends window to close") { [weak self] in
            self?.friendsWindow == nil
        }
        // Steam's FriendsUI finishes its own teardown a moment after the
        // popup manager forgets the window.
        try await Task.sleep(for: .milliseconds(300))
    }

    private static let friendsCloseScript = """
    (function () {
      var manager = window.g_PopupManager;
      if (!manager || !manager.m_mapPopups) return "no popup manager";
      var closed = 0;
      manager.m_mapPopups.forEach(function (popup) {
        if (String(popup.m_strName).indexOf("friendslist") !== 0) return;
        try { popup.m_popup.close(); closed++; } catch (e) {}
      });
      return String(closed);
    })()
    """

    private func benchmarkStep(
        target: BenchmarkTarget, iteration: Int,
        operation: () async throws -> Void,
    ) async throws -> BenchmarkSample {
        let clock = ContinuousClock()
        let started = clock.now
        _ = mainQueueLatency.snapshotAndReset()
        let interval = PerfProbe.benchmark.beginInterval(
            "ScenarioStep", id: PerfProbe.benchmark.makeSignpostID(),
            "target=\(target.rawValue, privacy: .public),iteration=\(iteration, privacy: .public)",
        )
        do {
            try await operation()
            let milliseconds = started.duration(to: clock.now).milliseconds
            PerfProbe.benchmark.endInterval(
                "ScenarioStep", interval,
                "target=\(target.rawValue, privacy: .public),iteration=\(iteration, privacy: .public),outcome=\("ready", privacy: .public)",
            )
            return BenchmarkSample(
                iteration: iteration, target: target.rawValue, milliseconds: milliseconds,
                outcome: "ready", detail: nil,
                mainThread: mainQueueLatency.snapshotAndReset(),
            )
        } catch is CancellationError {
            PerfProbe.benchmark.endInterval(
                "ScenarioStep", interval,
                "target=\(target.rawValue, privacy: .public),iteration=\(iteration, privacy: .public),outcome=\("cancelled", privacy: .public)",
            )
            throw CancellationError()
        } catch {
            let milliseconds = started.duration(to: clock.now).milliseconds
            PerfProbe.benchmark.endInterval(
                "ScenarioStep", interval,
                "target=\(target.rawValue, privacy: .public),iteration=\(iteration, privacy: .public),outcome=\("failed", privacy: .public)",
            )
            return BenchmarkSample(
                iteration: iteration, target: target.rawValue, milliseconds: milliseconds,
                outcome: "failed", detail: error.localizedDescription,
                mainThread: mainQueueLatency.snapshotAndReset(),
            )
        }
    }

    /// Steam's stores, not just its window. A sample taken between the two
    /// clocks measures a page still assembling itself, and the library route
    /// into it throws inside Steam's own code.
    private func waitForPageReady() async throws {
        try await waitForReadiness("Steam's stores") { [weak self] in
            await self?.evaluateInContext(
                "String(!!(window.__sevoIsReady && __sevoIsReady()))",
            ) == "true"
        }
    }

    private func waitForDesktopVisibility() async throws {
        try await waitForReadiness("visible desktop") { [weak self] in
            self?.desktop?.isWindowVisible == true
        }
    }

    private func waitForDesktopFrame() async throws {
        guard let webView = desktop?.webView else { throw BenchmarkFailure.desktopUnavailable }
        let token = UUID().uuidString
        let arm = """
        (function () {
          var token = \(JSLiteral.string(token));
          requestAnimationFrame(function () {
            requestAnimationFrame(function () { window.__sevoBenchmarkFrame = token; });
          });
          return token;
        })()
        """
        guard await evaluateInWebView(arm, webView: webView) == token else {
            throw BenchmarkFailure.commandRejected("could not arm desktop frame")
        }
        try await waitForReadiness("two desktop frames") { [weak self] in
            guard let desktop = self?.desktop else { return false }
            return await self?.evaluateInWebView(
                "String(window.__sevoBenchmarkFrame || '')", webView: desktop.webView,
            ) == token
        }
    }

    private func waitForStoreBrowserView() async throws {
        try await waitForReadiness("settled Store BrowserView") { [weak self] in
            self?.desktop?.hasSettledStoreBrowserView == true
        }
    }

    private func waitForFriendsWindow() async throws {
        try await waitForReadiness("visible Friends window") { [weak self] in
            self?.popups.values.contains { $0.role == .friends && $0.isWindowVisible } == true
        }
    }

    private func waitForReadiness(
        _ signal: String, timeout: Duration = .seconds(12),
        condition: () async -> Bool,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BenchmarkFailure.readinessTimedOut(signal)
    }

    private func requireBenchmarkCommand(_ reply: String?) throws {
        guard let reply,
              !["false", "0", "unavailable", "no browser context", "no navigator", "not ready"]
              .contains(reply)
        else { throw BenchmarkFailure.commandRejected(reply ?? "no reply") }
    }

    private func summary(for target: BenchmarkTarget, in samples: [BenchmarkSample]) -> BenchmarkSummary {
        let targetSamples = samples.filter { $0.target == target.rawValue }
        let timings = targetSamples.filter { $0.outcome == "ready" }.map(\.milliseconds).sorted()
        return BenchmarkSummary(
            target: target.rawValue,
            successfulSamples: timings.count,
            totalSamples: targetSamples.count,
            p50Milliseconds: Self.percentile(0.5, in: timings),
            p95Milliseconds: Self.percentile(0.95, in: timings),
            maxMainThreadDelayMilliseconds: targetSamples
                .map(\.mainThread.maxDelayMilliseconds).max() ?? 0,
        )
    }

    private static func percentile(_ fraction: Double, in sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[index]
    }

    private static let libraryBenchmarkScript = """
    (function () {
      if (!window.__sevoIsReady || !__sevoIsReady()) return "not ready";
      var window_ = window.SteamUIStore && SteamUIStore.WindowStore
        && SteamUIStore.WindowStore.MainWindowInstance;
      var nav = window_ && window_.Navigator;
      if (!nav || typeof nav.Home !== "function") return "no navigator";
      nav.Home();
      return "queued";
    })()
    """

    private static let storeBenchmarkScript = """
    (function () {
      if (typeof window.__sevoRunSteamURL !== "function") return "unavailable";
      if (!window.__sevoIsReady || !__sevoIsReady()) return "not ready";
      return String(window.__sevoRunSteamURL("steam://store"));
    })()
    """

    private static let friendsPopupGoneScript = """
    (function () {
      var manager = window.g_PopupManager;
      if (!manager || !manager.m_mapPopups) return "true";
      var open = false;
      manager.m_mapPopups.forEach(function (popup) {
        if (String(popup.m_strName).indexOf("friendslist") === 0) open = true;
      });
      return String(!open);
    })()
    """

    private static let friendsBenchmarkScript = """
    (function () {
      var app = window.g_FriendsUIApp;
      if (!app || typeof app.GetDefaultBrowserContext !== "function") return "unavailable";
      var context = app.GetDefaultBrowserContext();
      if (!context || typeof app.ShowPopupFriendsList !== "function") return "no browser context";
      app.ShowPopupFriendsList(context, false, true);
      return "queued";
    })()
    """
}
