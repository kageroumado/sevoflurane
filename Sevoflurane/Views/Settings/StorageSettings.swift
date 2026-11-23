import SwiftUI

// MARK: - Storage

struct StorageSettings: View {
    let store: StorageStore
    var steam: SteamActions?
    let highlighted: SettingsAnchor?
    @State private var showsGames = false
    @State private var showsPrograms = false

    var body: some View {
        let breakdown = store.breakdown
        SettingsForm(highlighted: highlighted) {
            if let volume = store.volume, let breakdown {
                SettingsSection(
                    title: "\(volume.name)",
                    value: String(localized: "\(Self.size(volume.used)) of \(Self.size(volume.capacity)) used"),
                ) {
                    StorageVolumeOverview(breakdown: breakdown, legend: legend(of: breakdown))
                }
            }
            SettingsSection(
                title: "Sevoflurane", value: Self.size(store.total), isWorking: store.isMeasuring,
                footer: "Caches and downloads move to the Trash. Uninstall games in Steam.",
            ) {
                ForEach(store.entries) { entry in
                    let dot = breakdown?.kind(of: entry)?.color
                    if entry.id == StorageInventory.Entry.gamesID, !store.games.isEmpty {
                        row(entry, dot: dot, isExpanded: $showsGames)
                        if showsGames { gameList }
                    } else if entry.id == StorageInventory.Entry.programsID, !store.programs.isEmpty {
                        row(entry, dot: dot, isExpanded: $showsPrograms)
                        if showsPrograms { programList }
                    } else if entry.id != StorageInventory.Entry.programsID {
                        row(entry, dot: dot)
                    }
                }
                if store.needsClientRestart, let steam {
                    SettingsAction(
                        title: "Linked games",
                        caption: String(localized: "Steam shows linked and unlinked games after it restarts."),
                    ) {
                        Button("Restart Steam") {
                            store.applyPendingLinks()
                            steam.restartClient()
                            store.acknowledgeRestart()
                        }
                    }
                }
                if let error = store.problem {
                    SettingsNotice(.failure, error)
                }
            }
            StorageLibrariesSection(libraries: store.libraries, steam: steam)
            sharingSection
        }
        .task { await store.measure() }
    }

    /// The bar's segments in the order the rows list their entries, with the
    /// group and everything else last.
    private func legend(of breakdown: StorageBreakdown) -> [StorageBreakdown.Segment] {
        let order = Dictionary(
            store.entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first },
        )
        return breakdown.segments.enumerated()
            .sorted { ($0.element.id.rank(in: order), $0.offset) < ($1.element.id.rank(in: order), $1.offset) }
            .map(\.element)
    }

    /// Sizes as Steam accounts for them, so a row here matches what the
    /// client shows for the same game.
    private var gameList: some View {
        SettingsSublist {
            ForEach(store.games) { game in
                gameRow(game)
            }
        }
    }

    private func gameRow(_ game: StorageInventory.Game) -> some View {
        let linked = store.linkedGames.contains(game.id)
        return SettingsValue(
            title: "\(game.name)", value: Self.size(game.bytes), mark: linked ? .symbol("link") : .dot(nil),
        ) {
            if steam != nil || linked {
                SettingsAccessoryButton(
                    symbol: linked ? "link.badge.minus" : "trash",
                    label: linked
                        ? String(localized: "Remove the link to \(game.name). The files stay in their own bottle.")
                        : String(localized: "Uninstall \(game.name) through Steam. It asks first."),
                ) {
                    if linked {
                        store.unlink(game)
                    } else {
                        steam?.uninstall(game.id)
                    }
                }
            }
        }
    }

    /// The Windows programs added by hand: what each occupies, and the one
    /// button that forgets it.
    private var programList: some View {
        SettingsSublist {
            ForEach(store.programs) { program in
                SettingsValue(
                    title: "\(program.name)",
                    value: program.isInsideBottle ? Self.size(program.bytes) : "—",
                    caption: program.isInsideBottle
                        ? program.path : String(localized: "\(program.path) · stays in place"),
                    mark: .dot(nil),
                ) {
                    SettingsAccessoryButton(
                        symbol: "trash",
                        label: program.isInsideBottle
                            ? String(localized: "Remove \(program.name) and move its installed files to the Trash")
                            : String(localized: "Remove \(program.name) from the list. Its files remain in place."),
                    ) {
                        store.removeProgram(program)
                    }
                }
            }
        }
    }

    /// Games installed in other bottles, one Link away from playable here.
    @ViewBuilder private var sharingSection: some View {
        if !store.linkable.isEmpty || !store.pendingLinks.isEmpty {
            SettingsSection(
                title: "In your other bottles", anchor: .storageSharing,
                footer: "A link shares another bottle\u{2019}s copy of a game. One copy on disk, no second download. Steam verifies it on first launch. Each bottle keeps its own saves.",
            ) {
                ForEach(store.pendingLinks) { candidate in
                    SettingsAction(
                        title: "\(candidate.name)",
                        caption: String(localized: "Steam shows it after it restarts."),
                    ) {
                        SettingsStatus(.done, String(localized: "Linked"))
                    } accessory: {
                        SettingsAccessoryButton(
                            symbol: "arrow.uturn.backward", label: String(localized: "Undo the link"),
                        ) {
                            store.cancelPendingLink(candidate)
                        }
                    }
                }
                ForEach(store.linkable) { candidate in
                    SettingsAction(
                        title: "\(candidate.name)",
                        caption: String(localized: "In \u{201C}\(candidate.sourceBottle)\u{201D} · \(candidate.sourceEngine)"),
                    ) {
                        SettingsValueText(text: Self.size(candidate.bytes))
                        Button("Link") { store.link(candidate) }
                    }
                }
            }
            .highlightableSection(.storageSharing, highlighted: highlighted)
        }
    }

    /// One category. `dot` is the color of the bar segment that holds the
    /// entry. A row that opens a list carries a chevron where the others
    /// carry their trash button, so every dot, name and size sits in one
    /// column whichever kind of row it is.
    private func row(
        _ entry: StorageInventory.Entry, dot: Color?, isExpanded: Binding<Bool>? = nil,
    ) -> some View {
        let name = InterfaceCopy.localized(entry.name)
        // A dash for both "not measured yet" and "nothing there":
        // `ByteCountFormatter` says "Zero KB", which reads like a bug.
        return SettingsValue(
            title: "\(name)", value: entry.bytes <= 0 ? "—" : Self.size(entry.bytes),
            caption: InterfaceCopy.localized(entry.removal?.caution ?? entry.detail), mark: .dot(dot),
        ) {
            if let isExpanded {
                SettingsAccessoryButton(
                    symbol: isExpanded.wrappedValue ? "chevron.down" : "chevron.right",
                    label: isExpanded.wrappedValue
                        ? String(localized: "Hide \(name)") : String(localized: "Show \(name)"),
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
                }
            } else if entry.removal != nil {
                SettingsAccessoryButton(
                    symbol: "trash", label: String(localized: "Move \(name.lowercased()) to the Trash"),
                    isDisabled: entry.bytes <= 0,
                ) {
                    store.reclaim(entry)
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard let isExpanded else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
        }
        // Games is the one row search can reach; the rest are read, not
        // navigated to.
        .highlightable(
            entry.id == StorageInventory.Entry.gamesID ? .storageGames : nil,
            highlighted: highlighted,
        )
    }

    /// Sizes are formatted here for every pane that shows one.
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension String {
    /// An entry's place among the rows; a segment that stands for no single
    /// row sorts after them all.
    func rank(in order: [String: Int]) -> Int {
        order[self] ?? .max
    }
}

// MARK: - Game libraries

/// Where Steam keeps games: its own library inside the bottle, and any folder
/// added in Steam's settings, with the drive each is on. Libraries are Steam's
/// to add, so the way to one is Steam's own settings window.
private struct StorageLibrariesSection: View {
    let libraries: [StorageInventory.Library]
    let steam: SteamActions?

    var body: some View {
        SettingsSection(
            title: "Game libraries",
            footer: "Put a library on a drive formatted as APFS or Mac OS Extended. exFAT and FAT drives have no file permissions or links, which Wine and some games rely on.",
        ) {
            ForEach(libraries) { library in
                StorageLibraryRow(library: library)
            }
            if let steam {
                SettingsAction(
                    title: "Another library",
                    caption: String(localized: "Steam adds a library on any drive."),
                    mark: .dot(nil),
                ) {
                    Button("Open Steam Settings") { steam.openSteamSettings() }
                }
            }
        }
    }
}

private struct StorageLibraryRow: View {
    let library: StorageInventory.Library

    var body: some View {
        SettingsValue(
            title: "\(library.isInsideBottle ? String(localized: "Inside the bottle") : library.location)",
            value: summary,
            state: .warning(ifPresent: warning),
            mark: .symbol(library.isInsideBottle ? "internaldrive" : "externaldrive"),
        )
        .help(library.location)
    }

    private var summary: String {
        var parts = [library.games == 1 ? String(localized: "1 game") : String(localized: "\(library.games) games")]
        if library.bytes > 0 {
            parts.append(library.bytes.formatted(.byteCount(style: .file)))
        }
        if let available = library.available {
            parts.append(String(localized: "\(available.formatted(.byteCount(style: .file))) free"))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var warning: String? {
        switch library.fileSystem {
        case let .foreign(name):
            String(localized: "Games on this \(name) drive can fail. Reformat it as APFS, or move them in Steam.")
        case let .network(name):
            String(localized: "On a \(name) network share, updates and saves are slow and can fail.")
        case .mac, .unknown:
            nil
        }
    }
}
