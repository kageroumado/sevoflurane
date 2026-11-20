import AppKit
import Propofol
import SwiftUI

// MARK: - Games column

/// What to play: the recent games and the Windows programs, at that column's
/// own height. For a library past the recent five, scrolling brings every
/// installed game up from below, under its letter.
struct GamesColumn: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let graphics: GraphicsStore
    let quickLaunch: QuickLaunchStore
    let presentation: PopoverPresentation
    /// The height of the recent games and programs, which the scroll view
    /// takes.
    @State private var visibleHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    /// Bumped by a pin change. Held here, so a pin made in one list shows in
    /// the other.
    @State private var pinEdits = 0

    /// Whether the index adds anything beyond the recent rows.
    private var showsIndex: Bool {
        host.libraryGames.count > host.recentGames.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    RecentGames(
                        host: host, supervisor: supervisor, graphics: graphics,
                        pinEdits: pinEdits, onPinChanged: { pinEdits += 1 },
                    )
                    QuickLaunchPrograms(
                        quickLaunch: quickLaunch, activeLaunch: host.activeLaunch,
                        renderers: graphics.menuRenderers,
                    )
                    AddProgramRow(quickLaunch: quickLaunch)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                if showsIndex {
                    LibraryIndexList(
                        host: host, supervisor: supervisor, graphics: graphics,
                        pinEdits: pinEdits, onPinChanged: { pinEdits += 1 },
                    )
                }
            }
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: visibleHeight)
        // Every open starts at the recent games.
        .onChange(of: presentation.isSettling) { _, isSettling in
            if isSettling { position.scrollTo(edge: .top) }
        }
    }
}

private struct ColumnHeading: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row facts

/// What a game row reads from disk: its pin, restart need, Dock bundle and
/// build.
private nonisolated struct GameRowFacts: Equatable, Sendable {
    let pinned: Renderer?
    let restartFor: Renderer?
    let dockBundle: URL?
    /// What Play starts, for a game Steam sells a macOS build of.
    let macBuild: GameBuild?
}

/// Reads the rows' facts off the main actor, again whenever they can have
/// changed.
private struct GameRowFactsReader: ViewModifier {
    let games: [Int]
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let graphics: GraphicsStore
    let pinEdits: Int
    @Binding var facts: [Int: GameRowFacts]

    /// What the facts depend on. The booted record and a pin live in storage
    /// observation cannot see; the client rewrites the record when it boots and
    /// when a launch restages it, which is when `health` and `activeLaunch`
    /// move.
    private struct Key: Equatable {
        let games: [Int]
        let health: SupervisorHealth
        let launch: Int?
        let renderer: Renderer
        let pinEdits: Int
    }

    func body(content: Content) -> some View {
        content
            .task(id: Key(
                games: games,
                health: supervisor.health,
                launch: host.activeLaunch?.appID,
                renderer: graphics.selection.renderer,
                pinEdits: pinEdits,
            )) {
                facts = await Self.read(games)
            }
    }

    @concurrent
    private nonisolated static func read(_ games: [Int]) async -> [Int: GameRowFacts] {
        Dictionary(uniqueKeysWithValues: games.map { id in
            (id, GameRowFacts(
                pinned: GameConfig.game(id).renderer,
                restartFor: BottleGraphics.rendererNeedingRestart(forApp: id),
                dockBundle: GameLaunchers.dockableBundle(appID: id),
                macBuild: SteamAppInfo.platforms(appID: id).contains("macos")
                    ? GameConfig.game(id).build ?? .windows : nil,
            ))
        })
    }
}

// MARK: - Recent games

/// The library's five most recently played games, with no heading.
private struct RecentGames: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let graphics: GraphicsStore
    let pinEdits: Int
    let onPinChanged: () -> Void
    @State private var facts: [Int: GameRowFacts] = [:]

    var body: some View {
        content
            .modifier(GameRowFactsReader(
                games: host.recentGames.map(\.id), host: host, supervisor: supervisor,
                graphics: graphics, pinEdits: pinEdits, facts: $facts,
            ))
    }

    @ViewBuilder private var content: some View {
        let renderers = graphics.menuRenderers
        if host.recentGames.isEmpty {
            // An empty list would read as a failure, so say so, but only once
            // the client is up; while it starts the health card speaks.
            if supervisor.health == .healthy {
                Text("No games installed yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.sm)
            }
        } else {
            let activeLaunch = host.activeLaunch
            let heldInCloudSync = host.gamesHeldInCloudSync
            VStack(spacing: 1) {
                ForEach(host.recentGames) { game in
                    GameRow(
                        game: game,
                        launchDetail: activeLaunch.flatMap { $0.appID == game.id ? $0.detail : nil },
                        pinned: facts[game.id]?.pinned,
                        restartFor: facts[game.id]?.restartFor,
                        dockBundle: facts[game.id]?.dockBundle,
                        macBuild: facts[game.id]?.macBuild,
                        isHeldInCloudSync: heldInCloudSync.contains(game.id),
                        renderers: renderers,
                        supervisor: supervisor,
                        onPinChanged: onPinChanged,
                    )
                }
            }
        }
    }
}

// MARK: - Library index

/// Every installed game under the letter Steam's library sorts it by, in the
/// recent games' own rows.
private struct LibraryIndexList: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let graphics: GraphicsStore
    let pinEdits: Int
    let onPinChanged: () -> Void
    @State private var facts: [Int: GameRowFacts] = [:]

    var body: some View {
        let activeLaunch = host.activeLaunch
        let heldInCloudSync = host.gamesHeldInCloudSync
        let renderers = graphics.menuRenderers
        // Lazy: a library of hundreds asks for art only for the rows scrolled to.
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(LibraryIndex.sections(host.libraryGames)) { section in
                ColumnHeading(text: Text(verbatim: section.heading))
                ForEach(section.games) { game in
                    GameRow(
                        game: game,
                        launchDetail: activeLaunch.flatMap { $0.appID == game.id ? $0.detail : nil },
                        pinned: facts[game.id]?.pinned,
                        restartFor: facts[game.id]?.restartFor,
                        dockBundle: facts[game.id]?.dockBundle,
                        macBuild: facts[game.id]?.macBuild,
                        isHeldInCloudSync: heldInCloudSync.contains(game.id),
                        renderers: renderers,
                        supervisor: supervisor,
                        onPinChanged: onPinChanged,
                    )
                }
            }
        }
        .modifier(GameRowFactsReader(
            games: host.libraryGames.map(\.id), host: host, supervisor: supervisor,
            graphics: graphics, pinEdits: pinEdits, facts: $facts,
        ))
    }
}

private struct GameRow: View {
    let game: SteamWebHost.RecentGame
    /// What the client says it is doing for this app (game-action events);
    /// `nil` outside a launch.
    let launchDetail: String?
    let pinned: Renderer?
    /// The renderer this launch would have to restart the client for.
    let restartFor: Renderer?
    let dockBundle: URL?
    let macBuild: GameBuild?
    /// The client has kept this game at Synchronizing for longer than a sync takes.
    let isHeldInCloudSync: Bool
    let renderers: [Renderer]
    let supervisor: ClientSupervisor
    let onPinChanged: () -> Void
    @State private var isHovered = false
    /// Instant acknowledgment for the click, until the client's first
    /// game-action event; an 8 s fallback if none arrives.
    @State private var isLaunching = false
    private static let acknowledgmentLife = Duration.seconds(8)

    var body: some View {
        Button {
            guard !isLaunching else { return }
            launch()
            withAnimation(.easeInOut(duration: 0.15)) { isLaunching = true }
        } label: {
            label
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(verbatim: game.name))
        .accessibilityValue(status?.line ?? (isLaunching ? Text("Launching") : Text(verbatim: "")))
        .accessibilityHint("Plays the game")
        .accessibilityAction(named: "Game Settings") {
            GameSettingsItem.open(id: game.id, name: game.name)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .task(id: isLaunching) {
            guard isLaunching else { return }
            try? await Task.sleep(for: Self.acknowledgmentLife)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { isLaunching = false }
        }
        .modifier(DockDrag(bundle: dockBundle))
        .contextMenu { menuItems }
    }

    /// The capsule art, the name over its status line, and the trailing
    /// control.
    private var label: some View {
        HStack(spacing: Theme.Space.md) {
            capsuleArt
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: game.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if let status {
                    status.line
                        .font(.system(size: 10))
                        .foregroundStyle(status.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            trailing
        }
        // No horizontal inset: the art, the Open Steam button and the
        // footer chips share the popover's padding as one edge.
        .padding(.vertical, Theme.Space.xs)
        .contentShape(Theme.innerShape)
    }

    /// The row's context menu: a one-off renderer, the pin, the build, the
    /// Dock and the game's settings.
    @ViewBuilder private var menuItems: some View {
        // For this run: the launch path restages the tree (or restarts, if
        // the engine or sync must change) before the game starts, and the
        // run's end hands the bottle back its own renderer.
        Menu("Run with…") {
            ForEach(renderers, id: \.self) { renderer in
                Button(renderer.label) { runWith(renderer) }
            }
        }
        Divider()
        // The pin stays listed when no longer offered, so the menu shows
        // what the game is set to.
        Picker("Always run with", selection: pinBinding) {
            Text("Bottle default").tag(Renderer?.none)
            ForEach(GraphicsStore.pinChoices(renderers, pinned: pinned), id: \.self) { renderer in
                Text(renderer.label).tag(Renderer?.some(renderer))
            }
        }
        if macBuild != nil {
            Picker("Play", selection: buildBinding) {
                ForEach(GameBuild.allCases, id: \.self) { build in
                    Text(build.label).tag(build)
                }
            }
        }
        Divider()
        KeepInDockItem(bundle: dockBundle)
        GameSettingsItem(id: game.id, name: game.name)
    }

    /// The line under the name: what the client is doing with the game, or what
    /// its next launch will do. VoiceOver reads it as the row's value.
    private var status: (line: Text, isWarning: Bool)? {
        if let launchDetail {
            return (Text(verbatim: launchDetail), false)
        }
        if game.isInCloudSync {
            return isHeldInCloudSync
                ? (Text("Steam is stuck synchronizing. Restart Steam to play."), true)
                : (Text("Synchronizing with Steam Cloud"), false)
        }
        if macBuild == .mac {
            return (Text("Plays in Steam for Mac"), false)
        }
        if let restartFor {
            // Pinned to a renderer the client did not boot with: said before
            // the click, since the launch will restage or restart.
            return (Text("\(restartFor.label) · set when it launches"), false)
        }
        return nil
    }

    /// The press claims the activation right the game's window spends a minute
    /// later. The popover must stay a non-activating panel, or every click in
    /// it would pull focus, so the press claims it explicitly.
    private func launch() {
        ActivationPolicy.claimRightForALaunch()
        Task(name: "Launch \(game.name)") { await supervisor.launch(game) }
    }

    private func runWith(_ renderer: Renderer) {
        ActivationPolicy.claimRightForALaunch()
        Task(name: "Run \(game.name) on \(renderer.label)") {
            await supervisor.launch(game, renderer: renderer)
        }
    }

    private func setPin(_ renderer: Renderer?) {
        GameConfig.update(
            game: game.id, bottle: SteamBottle.name, prefix: SteamBottle.root, inBackground: true,
        ) {
            $0.renderer = renderer
            if $0.name == nil { $0.name = game.name }
        }
        onPinChanged()
    }

    /// Which build Play starts; Windows is the default, which no file holds.
    private var buildBinding: Binding<GameBuild> {
        Binding(get: { macBuild ?? .windows }, set: { build in
            GameConfig.update(
                game: game.id, bottle: SteamBottle.name, prefix: SteamBottle.root, inBackground: true,
            ) {
                $0.build = build == .mac ? .mac : nil
                if $0.name == nil { $0.name = game.name }
            }
            onPinChanged()
        })
    }

    private var pinBinding: Binding<Renderer?> {
        Binding(get: { pinned }, set: { setPin($0) })
    }

    private var capsuleArt: some View {
        AsyncImage(url: game.artURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary.opacity(0.5))
        }
        .frame(width: 27, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// The Play badge; it spins for the length of a launch.
    private var trailing: some View {
        PlayBadge(isBusy: isLaunching || launchDetail != nil, isHovered: isHovered)
    }
}

// MARK: - Quick Launch

/// The Windows programs the user handed to Sevoflurane, in the games' column,
/// since they launch the same way.
private struct QuickLaunchPrograms: View {
    let quickLaunch: QuickLaunchStore
    /// The launch under way, which a program's row reads its status from as a
    /// game's does.
    let activeLaunch: SteamWebHost.GameLaunch?
    let renderers: [Renderer]

    var body: some View {
        ForEach(quickLaunch.programs) { entry in
            ProgramRow(
                entry: entry,
                icon: quickLaunch.icon(for: entry),
                quickLaunch: quickLaunch,
                launchDetail: activeLaunch.flatMap { $0.appID == entry.id ? $0.detail : nil },
                isLaunching: quickLaunch.launching.contains(entry.id),
                renderers: renderers,
            )
        }
    }
}

/// One adopted program, drawn like a game's row (Play badge and status line
/// included), started through the daemon.
private struct ProgramRow: View {
    let entry: AdoptedPrograms.Entry
    let icon: NSImage?
    let quickLaunch: QuickLaunchStore
    let launchDetail: String?
    /// Its launch request is with the helper, which a first HoYoverse launch
    /// keeps for a quarter of a minute while it makes the companion prefix.
    let isLaunching: Bool
    let renderers: [Renderer]
    @State private var isHovered = false
    @State private var dockBundle: URL?
    /// The name being typed; `nil` outside a rename.
    @State private var draftName: String?
    @FocusState private var isEditingName: Bool

    var body: some View {
        if draftName != nil {
            renameRow
        } else {
            playRow
        }
    }

    /// The name as a field: Return keeps it, Escape or a click elsewhere drops
    /// it.
    private var renameRow: some View {
        HStack(spacing: Theme.Space.md) {
            artwork
            TextField("Name", text: Binding(
                get: { draftName ?? entry.name },
                set: { draftName = $0 },
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($isEditingName)
            .onSubmit {
                if let draftName { quickLaunch.rename(entry, to: draftName) }
                self.draftName = nil
            }
            .onExitCommand { draftName = nil }
            .onChange(of: isEditingName) { _, focused in
                if !focused { draftName = nil }
            }
            Spacer(minLength: Theme.Space.sm)
        }
        .padding(.vertical, Theme.Space.xs)
        .onAppear { isEditingName = true }
    }

    private var playRow: some View {
        Button {
            quickLaunch.launch(entry)
        } label: {
            HStack(spacing: Theme.Space.md) {
                artwork
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if !entry.program.exists {
                        Text("moved or deleted")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let launchDetail {
                        Text(verbatim: launchDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                if entry.program.exists {
                    PlayBadge(isBusy: isLaunching || launchDetail != nil, isHovered: isHovered)
                }
            }
            .padding(.vertical, Theme.Space.xs)
            .contentShape(Theme.innerShape)
        }
        .buttonStyle(PressableStyle())
        .disabled(!entry.program.exists)
        .accessibilityLabel(Text(verbatim: entry.name))
        .accessibilityHint("Plays the game")
        .accessibilityAction(named: "Game Settings") {
            GameSettingsItem.open(id: entry.id, name: entry.name)
        }
        .background(Color.primary.opacity(isHovered ? 0.07 : 0), in: Theme.innerShape)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .modifier(DockDrag(bundle: dockBundle))
        .task(id: "\(entry.id) \(entry.name)") { dockBundle = await Self.readDockBundle(entry.id) }
        .contextMenu { menuItems }
    }

    /// The program's context menu: a one-off renderer, the Dock, Steam's
    /// library, and the entry's own management.
    @ViewBuilder private var menuItems: some View {
        Menu("Run with…") {
            ForEach(renderers, id: \.self) { renderer in
                Button(renderer.label) { quickLaunch.launch(entry, renderer: renderer) }
            }
        }
        Divider()
        KeepInDockItem(bundle: dockBundle)
        if SteamLibraryShortcuts.canList(entry.program) {
            Toggle("Show in Steam's Library", isOn: Binding(
                get: { entry.program.inSteamLibrary == true },
                set: { quickLaunch.setInSteamLibrary($0, for: entry) },
            ))
        }
        Button("Rename…") { draftName = entry.name }
        Button("Show in Finder") { quickLaunch.showInFinder(entry) }
        Button("Remove") { quickLaunch.remove(entry) }
        Divider()
        GameSettingsItem(id: entry.id, name: entry.name)
    }

    @concurrent
    private nonisolated static func readDockBundle(_ id: Int) async -> URL? {
        GameLaunchers.dockableBundle(appID: id)
    }

    private var artwork: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 27, height: 27)
        .padding(.vertical, 6)
    }
}

// MARK: - Dock

/// Keeps the game's own bundle in the Dock, offered once a launch has built it.
private struct KeepInDockItem: View {
    let bundle: URL?

    var body: some View {
        if let bundle {
            Button("Keep in Dock") { DockTiles.keep(bundle) }
        }
    }
}

private struct DockDrag: ViewModifier {
    let bundle: URL?

    func body(content: Content) -> some View {
        if let bundle {
            content.onDrag { NSItemProvider(object: bundle as NSURL) }
        } else {
            content
        }
    }
}

/// The line that adds a program, under the last row in a smaller hand.
private struct AddProgramRow: View {
    let quickLaunch: QuickLaunchStore
    @State private var isHovered = false

    var body: some View {
        Button {
            quickLaunch.chooseProgram()
        } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 27)
                Text("Add Windows Game…")
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
            }
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.vertical, 3)
            .contentShape(.rect)
            // Evens the gap with the row's own `xs` padding above and the
            // popover's `sm` spacing below.
            .padding(.top, Theme.Space.xs)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

/// The context-menu way into a game's page in Settings › Games.
struct GameSettingsItem: View {
    let id: Int
    let name: String

    var body: some View {
        Button("Game Settings…") { Self.open(id: id, name: name) }
    }

    static func open(id: Int, name: String) {
        (NSApp.delegate as? AppDelegate)?.showGameSettings(id: id, name: name)
    }
}
