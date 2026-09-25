import AppKit
import SwiftUI
import Testing
@testable import Sevoflurane

/// The process monitor: what it calls each thing, and that both diagnostic
/// windows lay out against real data rather than only compiling.
@MainActor
struct ProcessMonitorTests {
    @Test
    func `every role and state has a name and a colour of its own`() {
        let titles = StallWatch.Role.allCases.map(\.title)
        #expect(Set(titles).count == StallWatch.Role.allCases.count)
        #expect(titles.contains("game child"))
        #expect(StallWatch.State.stalled.tint == .red)
        #expect(StallWatch.State.stopped.tint == .orange)
        #expect(StallWatch.State.running.tint == .green)
    }

    @Test
    func `collecting a report for something that is not a game says so`() {
        let watch = StallWatch()
        let actions = ProcessMonitorActions(watch: watch)
        actions.collectReports(Self.process(role: .helper, appID: nil))
        #expect(actions.note?.contains("not a game") == true)
    }

    // MARK: - The windows lay out

    @Test
    func `the process monitor lays out over the watchdog's samples`() {
        let watch = StallWatch()
        let window = Self.window(around: ProcessMonitorView(watch: watch))
        defer { window.close() }
        settle(window)
        #expect(window.contentView?.subviews.isEmpty == false)
    }

    @Test
    func `the report window lays out with whatever runs this Mac has`() {
        let window = Self.window(around: ReportView())
        defer { window.close() }
        settle(window)
        #expect(window.contentView?.subviews.isEmpty == false)
    }

    @Test
    func `the diagnostics pane lays out at every level`() {
        for anchor in [SettingsAnchor.diagnosticsLevel, .diagnosticsGuide, .diagnosticsReports, .diagnosticsCaps] {
            let window = Self.window(around: DiagnosticsSettings(highlighted: anchor))
            defer { window.close() }
            settle(window)
            #expect(window.contentView?.subviews.isEmpty == false)
        }
    }

    // MARK: - Scratch

    private static func process(
        role: StallWatch.Role, appID: Int?,
    ) -> StallWatch.Process {
        StallWatch.Process(
            pid: 900, name: "game.exe", role: role, cpuSeconds: 12, cpuShare: 0.5,
            footprintBytes: 1 << 20, presents: nil, state: .running, appID: appID,
        )
    }

    private static func window(around view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        return window
    }

    /// Runs the main loop until SwiftUI has laid the view out.
    private func settle(_ window: NSWindow) {
        for _ in 0 ..< 8 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
