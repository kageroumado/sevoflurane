import Propofol
import SwiftUI

// MARK: - Storage

struct StorageSettings: View {
    let store: StorageStore
    var steam: SteamActions?
    let highlighted: SettingsAnchor?

    var body: some View {
        Form {
            Section {
                ForEach(store.entries) { entry in
                    if entry.id == StorageInventory.Entry.gamesID, !store.games.isEmpty {
                        DisclosureGroup { gameList } label: { row(entry) }
                    } else if entry.id == StorageInventory.Entry.programsID,
                              !store.programs.isEmpty {
                        DisclosureGroup { programList } label: { row(entry) }
                    } else if entry.id != StorageInventory.Entry.programsID {
                        row(entry)
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
                HStack {
                    Text("On this Mac")
                    Spacer()
                    if store.isMeasuring { ProgressView().controlSize(.small) }
                    Text(Self.size(store.total)).monospacedDigit().foregroundStyle(.secondary)
                }
            } footer: {
                Text("Caches and downloads go to the Trash. Uninstall games through Steam.")
            }
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
        .padding(.leading, 28)
        .padding(.vertical, 4)
    }

    private func gameRow(_ game: StorageInventory.Game) -> some View {
        let linked = store.linkedGames.contains(game.id)
        return HStack {
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
        .padding(.leading, 28)
        .padding(.vertical, 4)
    }

    private func programRow(_ program: StorageInventory.Program) -> some View {
        HStack {
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

    private func row(_ entry: StorageInventory.Entry) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: entry.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(entry.removal?.caution ?? entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)
            // A dash for both "not measured yet" and "nothing there":
            // `ByteCountFormatter` says "Zero KB", which reads like a bug.
            Text(entry.bytes <= 0 ? "—" : Self.size(entry.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if entry.removal != nil {
                Button { store.reclaim(entry) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(entry.bytes <= 0)
                    .help("Move \(entry.name.lowercased()) to the Trash")
            }
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
