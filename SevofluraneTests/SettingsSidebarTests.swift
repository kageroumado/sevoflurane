import AppKit
import SwiftUI
import Testing
@testable import Sevoflurane

/// The Settings sidebar under the churn that crashed the app: the search
/// field cycling between empty and a needle every pane matches, while the
/// selection moves in the same update.
///
/// The list must stay one kind of row throughout. A `Section` header row
/// beside content rows gives AppKit's table a header row view and a content
/// row view to constrain against each other across a diff, and the leading
/// anchors it activates then belong to two different view hierarchies.
@MainActor
struct SettingsSidebarTests {
    /// Drives the sidebar's three bindings from outside the view tree.
    @Observable
    final class Bindings {
        var category = SettingsCategory.general
        var searchText = ""
        var highlighted: SettingsAnchor?
    }

    private struct Harness: View {
        @Bindable var bindings: Bindings

        var body: some View {
            NavigationSplitView {
                SettingsSidebar(
                    category: $bindings.category,
                    searchText: $bindings.searchText,
                    highlighted: $bindings.highlighted,
                )
            } detail: {
                Text(bindings.category.title)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    @Test
    func `fifty search cycles with a selection set leave the list standing`() {
        let bindings = Bindings()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Harness(bindings: bindings))
        window.orderFrontRegardless()
        defer { window.close() }

        for cycle in 0 ..< 50 {
            // Every pane matches a bare "e", so the list swings between six
            // rows and every row the app has.
            bindings.searchText = "e"
            settle(window)
            // Picking a result moves the selection while the widest set of
            // rows is on screen — the transaction the crash reported.
            bindings.category = cycle.isMultiple(of: 2) ? .engine : .games
            bindings.highlighted = .engineWindows
            settle(window)
            bindings.searchText = "en"
            settle(window)
            bindings.searchText = ""
            bindings.category = .general
            bindings.highlighted = nil
            settle(window)
        }
        #expect(bindings.searchText.isEmpty)
    }

    /// One display cycle: SwiftUI applies the update, AppKit lays the table
    /// out, and Core Animation commits — which is the frame the crash was in.
    private func settle(_ window: NSWindow) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        window.layoutIfNeeded()
        CATransaction.flush()
    }
}

/// Search and the panes name the same rows. A searchable setting with no row
/// to flash sends the user to a pane and then stops; a row with an anchor
/// nothing searches for can only be found by scrolling.
@MainActor
struct SettingsSearchTests {
    @Test
    func `every searchable setting has a row, and every row is searchable`() {
        let searchable = Set(
            SettingsCategory.allCases.flatMap { $0.searchableItems.map(\.id) },
        )
        #expect(searchable == Set(SettingsAnchor.allCases))
    }

    @Test
    func `an id belongs to exactly one setting, in its own pane`() {
        var seen: Set<SettingsAnchor> = []
        for category in SettingsCategory.allCases {
            for item in category.searchableItems {
                #expect(seen.insert(item.id).inserted, "\(item.id.rawValue) is listed twice")
                #expect(
                    item.id.rawValue.hasPrefix("\(category.rawValue)."),
                    "\(item.id.rawValue) is listed under \(category.rawValue)",
                )
            }
        }
    }

    @Test
    func `the holes the playtest found are closed`() {
        let searchable = SettingsCategory.allCases.flatMap(\.searchableItems)
        for anchor in [
            SettingsAnchor.gamesUpscaler, .aboutDiagnostics, .engineMouse, .engineWineDiagnostics,
        ] {
            #expect(searchable.contains { $0.id == anchor })
        }
        // The searches that reached nothing: each names its pane's setting now.
        for needle in ["upscaler", "diagnostics", "mouse"] {
            let panes = SettingsCategory.allCases.filter { category in
                category.searchableItems.contains { $0.matches(needle) }
            }
            #expect(panes.count >= 2, "\(needle) reaches only \(panes.map(\.rawValue))")
        }
    }
}
