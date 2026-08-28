import SwiftUI

/// Settings: General (login item), Graphics (the bottle's renderer knobs),
/// Repair (the idempotent provisioner, re-run on demand), About. The wizard
/// covers first run; this is everything after it.
///
/// A searchable sidebar rather than a row of tabs, because the knobs that
/// bring someone here are the ones they know by name — "msync", "renderer",
/// "open at login" — and not by which pane happens to hold them. Searching
/// lists the matching settings themselves; picking one opens its pane and
/// flashes the row.
struct SettingsView: View {
    let provisioner: Provisioner
    @State private var category: SettingsCategory = .general
    @State private var searchText = ""
    @State private var highlighted: String?

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                category: $category,
                searchText: $searchText,
                highlighted: $highlighted,
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPane(
                category: category,
                provisioner: provisioner,
                highlighted: highlighted,
            )
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case graphics
    case repair
    case about

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .general: "General"
        case .graphics: "Graphics"
        case .repair: "Repair"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .graphics: "cpu.fill"
        case .repair: "wrench.and.screwdriver.fill"
        case .about: "info.circle.fill"
        }
    }

    /// What search matches on — one entry per row a pane can flash.
    var searchableItems: [SearchableSetting] {
        switch self {
        case .general:
            [SearchableSetting(
                id: "general.openAtLogin",
                title: "Open at login",
                keywords: ["login", "startup", "start", "launch", "menu bar", "automatic"],
            )]
        case .graphics:
            [
                SearchableSetting(
                    id: "graphics.renderer",
                    title: "Game renderer",
                    keywords: [
                        "renderer", "graphics", "direct3d", "d3d", "d3dmetal",
                        "dxmt", "dxvk", "wined3d", "gpu", "metal",
                    ],
                ),
                SearchableSetting(
                    id: "graphics.gpu",
                    title: "Report the GPU as",
                    keywords: [
                        "gpu", "graphics card", "nvidia", "geforce", "amd", "radeon",
                        "vendor", "driver", "outdated", "unsupported",
                    ],
                ),
                SearchableSetting(
                    id: "graphics.msync",
                    title: "Enhanced synchronization (msync)",
                    keywords: [
                        "msync", "sync", "synchronization", "performance",
                        "deadlock", "hang",
                    ],
                ),
            ]
        case .repair:
            [SearchableSetting(
                id: "repair.run",
                title: "Repair the installation",
                keywords: [
                    "repair", "reinstall", "fix", "setup", "provision",
                    "broken", "engine", "bottle",
                ],
            )]
        case .about:
            [SearchableSetting(
                id: "about.version",
                title: "Version",
                keywords: ["about", "version", "build", "github", "source", "kageroumado"],
            )]
        }
    }
}

struct SearchableSetting: Identifiable, Equatable {
    let id: String
    let title: String
    let keywords: [String]

    func matches(_ search: String) -> Bool {
        let needle = search.lowercased()
        return title.lowercased().contains(needle) || keywords.contains { $0.contains(needle) }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var category: SettingsCategory
    @Binding var searchText: String
    @Binding var highlighted: String?

    private var results: [(category: SettingsCategory, items: [SearchableSetting])] {
        SettingsCategory.allCases.compactMap { category in
            let items = category.searchableItems.filter { $0.matches(searchText) }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        List(selection: $category) {
            if searchText.isEmpty {
                ForEach(SettingsCategory.allCases) { category in
                    Label {
                        Text(category.title)
                    } icon: {
                        Image(systemName: category.icon)
                            .foregroundStyle(Color.accentColor)
                    }
                    .tag(category)
                }
            } else {
                ForEach(results, id: \.category.id) { result in
                    Section {
                        ForEach(result.items) { item in
                            Button { reveal(item, in: result.category) } label: {
                                HStack {
                                    Text(item.title).foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label(result.category.title, systemImage: result.category.icon)
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Settings")
        .navigationTitle("Settings")
        .frame(minWidth: 190)
    }

    /// Opens the setting's pane and flashes its row, long enough to find with
    /// the eye and short enough not to stay behind as decoration.
    private func reveal(_ item: SearchableSetting, in category: SettingsCategory) {
        self.category = category
        highlighted = item.id
        Task(name: "Clear settings highlight") {
            try? await Task.sleep(for: .seconds(1.8))
            highlighted = nil
        }
    }
}

// MARK: - Panes

private struct SettingsPane: View {
    let category: SettingsCategory
    let provisioner: Provisioner
    let highlighted: String?

    var body: some View {
        Group {
            switch category {
            case .general: GeneralSettings(provisioner: provisioner, highlighted: highlighted)
            case .graphics: GraphicsSettings(highlighted: highlighted)
            case .repair: RepairSettings(provisioner: provisioner, highlighted: highlighted)
            case .about: AboutSettings(highlighted: highlighted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(category.title)
    }
}

/// Flashes a row the search sent the user to.
private struct HighlightModifier: ViewModifier {
    let id: String
    let highlighted: String?

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(highlighted == id ? Color.accentColor.opacity(0.2) : .clear)
                    .animation(.easeInOut(duration: 0.3), value: highlighted),
            )
    }
}

extension View {
    func highlightable(id: String, highlighted: String?) -> some View {
        modifier(HighlightModifier(id: id, highlighted: highlighted))
    }
}
