import Propofol
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
        return Form {
            if let volume = store.volume, let breakdown {
                Section {
                    StorageVolumeOverview(volume: volume, breakdown: breakdown)
                }
            }
            Section {
                ForEach(store.entries) { entry in
                    let dot = breakdown?.kind(of: entry)?.color
                    if entry.id == StorageInventory.Entry.gamesID, !store.games.isEmpty {
                        row(entry, dot: dot, isExpanded: $showsGames)
                        if showsGames { gameList }
                    } else if entry.id == StorageInventory.Entry.programsID,
                              !store.programs.isEmpty {
                        row(entry, dot: dot, isExpanded: $showsPrograms)
                        if showsPrograms { programList }
                    } else if entry.id != StorageInventory.Entry.programsID {
                        row(entry, dot: dot)
                    }
                }
                if store.needsClientRestart, let steam {
                    HStack {
                        Text("Restart Steam to see linked and unlinked games.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Steam") {
                            store.applyPendingLinks()
                            steam.restartClient()
                            store.acknowledgeRestart()
                        }
                    }
                }
                if let error = store.problem {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            } header: {
                StorageOwnTotalHeader(total: store.total, isMeasuring: store.isMeasuring)
            } footer: {
                Text("Caches and downloads go to the Trash. Uninstall games through Steam.")
            }
            StorageLibrariesSection(libraries: store.libraries, steam: steam)
            sharingSection
        }
        .formStyle(.grouped)
        .task { await store.measure() }
    }

    /// Sizes as Steam accounts for them, so a row here matches what the
    /// client shows for the same game.
    private var gameList: some View {
        VStack(spacing: 4) {
            ForEach(store.games) { game in
                gameRow(game)
            }
        }
        .padding(.leading, Self.titleIndent)
        .padding(.vertical, Theme.Space.xs)
    }

    private func gameRow(_ game: StorageInventory.Game) -> some View {
        let linked = store.linkedGames.contains(game.id)
        return HStack(spacing: Theme.Space.md) {
            Text(game.name).lineLimit(1)
            if linked {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Shared from another bottle. One copy on disk.")
            }
            Spacer(minLength: Theme.Space.md)
            Text(Self.size(game.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Group {
                if steam != nil || linked {
                    Button {
                        if linked {
                            store.unlink(game)
                        } else {
                            steam?.uninstall(game.id)
                        }
                    } label: {
                        Image(systemName: linked ? "link.badge.minus" : "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(linked
                        ? "Remove the link. The files stay in their own bottle."
                        : "Uninstall through Steam. It asks first.")
                }
            }
            .frame(width: Self.actionColumnWidth)
        }
        .font(.callout)
    }

    /// The Windows programs added by hand: what each occupies, and the one
    /// button that forgets it.
    private var programList: some View {
        VStack(spacing: 4) {
            ForEach(store.programs) { program in
                programRow(program)
            }
        }
        .padding(.leading, Self.titleIndent)
        .padding(.vertical, Theme.Space.xs)
    }

    private func programRow(_ program: StorageInventory.Program) -> some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(program.name).lineLimit(1)
                Text(program.isInsideBottle
                    ? program.path
                    : "\(program.path) · stays in place")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Theme.Space.md)
            Text(program.isInsideBottle ? Self.size(program.bytes) : "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                store.removeProgram(program)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(width: Self.actionColumnWidth)
            .help(program.isInsideBottle
                ? "Remove it and move what its installer wrote to the Trash."
                : "Remove it. The program's own files stay where they are.")
        }
        .font(.callout)
    }

    /// Games installed in other bottles, one Link away from playable here.
    @ViewBuilder private var sharingSection: some View {
        if !store.linkable.isEmpty || !store.pendingLinks.isEmpty {
            Section {
                ForEach(store.pendingLinks) { candidate in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.name).lineLimit(1)
                            Text("Linked. Appears after a Steam restart.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.md)
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            store.cancelPendingLink(candidate)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Undo the link")
                    }
                    .font(.callout)
                }
                ForEach(store.linkable) { candidate in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.name).lineLimit(1)
                            Text("In \u{201C}\(candidate.sourceBottle)\u{201D} · \(candidate.sourceEngine)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.md)
                        Text(Self.size(candidate.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Link") { store.link(candidate) }
                    }
                    .font(.callout)
                }
            } header: {
                Text("In your other bottles")
            } footer: {
                Text("A link shares another bottle's copy of a game. One copy "
                    + "on disk, no second download. Steam verifies it on first "
                    + "launch. Each bottle keeps its own saves.")
            }
            .highlightable(.storageSharing, highlighted: highlighted)
        }
    }

    /// The column at the trailing edge that holds a row's one control, kept
    /// for a row with none so the sizes share an edge.
    private static let actionColumnWidth: CGFloat = 20
    /// Where a row's title starts, past its dot: the edge the detail line and
    /// the expanded lists share.
    private static let titleIndent = StorageDot.diameter + Theme.Space.sm

    /// One category. `dot` is the color of the bar segment that holds the
    /// entry. A row that opens a list carries a chevron where the others
    /// carry their trash button, so every dot, name and size sits in one
    /// column whichever kind of row it is.
    private func row(
        _ entry: StorageInventory.Entry, dot: Color?, isExpanded: Binding<Bool>? = nil,
    ) -> some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.sm) {
                    StorageDot(color: dot)
                    Text(entry.name)
                }
                Text(entry.removal?.caution ?? entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.titleIndent)
            }
            Spacer(minLength: Theme.Space.sm)
            // A dash for both "not measured yet" and "nothing there":
            // `ByteCountFormatter` says "Zero KB", which reads like a bug.
            Text(entry.bytes <= 0 ? "—" : Self.size(entry.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Group {
                if let isExpanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    }
                    .help(isExpanded.wrappedValue ? "Hide the list" : "Show each one")
                    .accessibilityLabel(isExpanded.wrappedValue ? "Hide \(entry.name)" : "Show \(entry.name)")
                } else if entry.removal != nil {
                    Button { store.reclaim(entry) } label: { Image(systemName: "trash") }
                        .disabled(entry.bytes <= 0)
                        .help("Move \(entry.name.lowercased()) to the Trash")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: Self.actionColumnWidth)
        }
        .contentShape(Rectangle())
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

/// The header over the list of what Sevoflurane itself occupies.
struct StorageOwnTotalHeader: View {
    let total: Int64
    let isMeasuring: Bool

    var body: some View {
        HStack {
            Text("Sevoflurane")
            Spacer()
            if isMeasuring { ProgressView().controlSize(.small) }
            Text(StorageSettings.size(total)).monospacedDigit().foregroundStyle(.secondary)
        }
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
        Section {
            ForEach(libraries) { library in
                StorageLibraryRow(library: library)
            }
            if let steam {
                HStack {
                    Text("Add a library in Steam\u{2019}s settings, under Storage.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Steam Settings\u{2026}") { steam.openSteamSettings() }
                }
            }
        } header: {
            Text("Game libraries")
        } footer: {
            Text("Put a library on a drive formatted as APFS or Mac OS Extended. exFAT and FAT drives "
                + "have no file permissions or links, which Wine and some games rely on.")
        }
    }
}

private struct StorageLibraryRow: View {
    let library: StorageInventory.Library

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: library.isInsideBottle ? "internaldrive" : "externaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(library.isInsideBottle ? "Inside the bottle" : library.location)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help(library.location)
    }

    private var summary: String {
        var parts = [library.games == 1 ? "1 game" : "\(library.games) games"]
        if library.bytes > 0 {
            parts.append(library.bytes.formatted(.byteCount(style: .file)))
        }
        if let available = library.available {
            parts.append("\(available.formatted(.byteCount(style: .file))) free")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var warning: String? {
        switch library.fileSystem {
        case let .foreign(name):
            "This drive is \(name). Games here can fail to install, update or start. "
                + "Reformat it as APFS, or move the games to another library in Steam."
        case let .network(name):
            "This library is on a \(name) network share. Updates and saves are slow and can fail there."
        case .mac, .unknown:
            nil
        }
    }
}
