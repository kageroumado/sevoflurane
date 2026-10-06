import AppKit
import Propofol
import SwiftUI

// MARK: - Games column

/// What to play: the recent games and the Windows programs, the column the
/// popover has always shown, at that column's own height. For a library
/// bigger than the recent five, scrolling it brings every installed game up
/// from below, under its letter; until then nothing hints at them, so the
/// popover stands exactly as it did.
struct GamesColumn: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let graphics: GraphicsStore
    let quickLaunch: QuickLaunchStore
    let presentation: PopoverPresentation
    /// The height of the recent games and the programs, which the scroll
    /// view stands at.
    @State private var visibleHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    /// Bumped by a pin change, which rewrites a game's config. Held here, so a
    /// game pinned in one list reads as pinned in the other too.
    @State private var pinEdits = 0

    /// Whether the index adds anything: a library the recent rows already
    /// show whole needs no second copy under letters.
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
        // Every open starts at the recent games, not wherever the last one
        // was left.
        .onChange(of: presentation.isSettling) { _, isSettling in
            if isSettling { position.scrollTo(edge: .top) }
        }
    }
}

/// A letter heading in the index, in the small hand the column's other
/// secondary lines use.
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

/// What a game row reads from disk: its pin, its restart need and the
/// bundle it can be kept in the Dock as.
private nonisolated struct GameRowFacts: Equatable, Sendable {
    let pinned: Renderer?
    let restartFor: Renderer?
    let dockBundle: URL?
    /// What Play starts, for a game Steam sells a macOS build of.
    let macBuild: GameBuild?
}

/// Reads the rows' facts from the game configs off the main actor rather
/// than on every body evaluation, and again whenever they can have changed.
private struct GameRowFactsReader: ViewModifier {
    let games: [Int]
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    /// Its choice is what a row's restart need is measured against.
    let graphics: GraphicsStore
    let pinEdits: Int
    @Binding var facts: [Int: GameRowFacts]

    /// What the facts depend on: the rows, and the moments the booted record,
    /// the bottle's renderer or a pin can change. The booted record and a pin
    /// live in plain storage that observation cannot see; the client rewrites
    /// the record when it boots and when a launch restages it, which is when
    /// `health` and `activeLaunch` move.
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

/// The library's five most recently played games.
///
/// No heading: five pieces of box art under the app's own name need no
/// label to say they are games.
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
            // A popover with nothing between the header and the button reads
            // as a failure; a library with no installed games is not one.
            // Said only of a client that is up: while it starts, the list is
            // still loading and the health card says so.
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

/// Every installed game, under the letter Steam's library sorts it by, after
/// the recent games and the programs. The rows are the recent games' rows, so
/// a game plays, pins and opens its settings the same from either list.
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

/// One game: its capsule art, its name, and a press that launches it.
private struct GameRow: View {
    let game: SteamWebHost.RecentGame
    /// What the client says it is doing right now for this app
    /// (game-action events); `nil` outside a launch.
    let launchDetail: String?
    /// The renderer this game is pinned to, if any.
    let pinned: Renderer?
    /// The renderer this launch would have to restart the client for.
    let restartFor: Renderer?
    /// The game's own bundle, once a launch has built one.
    let dockBundle: URL?
    /// What Play starts, for a game Steam sells a macOS build of.
    let macBuild: GameBuild?
    /// The client has kept this game at Synchronizing for longer than a sync takes.
    let isHeldInCloudSync: Bool
    /// The renderers the machine offers a game right now (``GraphicsStore/menuRenderers``).
    let renderers: [Renderer]
    let supervisor: ClientSupervisor
    let onPinChanged: () -> Void
    @State private var isHovered = false
    /// Instant acknowledgment for the click; the client's first
    /// game-action event takes over from it, and it stands alone as an
    /// 8s fallback if no events arrive.
    @State private var isLaunching = false
    private static let acknowledgmentLife = Duration.seconds(8)

    var body: some View {
        Button {
            guard !isLaunching else { return }
            launch()
            withAnimation(.easeInOut(duration: 0.15)) { isLaunching = true }
        } label: {
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
                // Flush with the trailing edge the footer's buttons and the
                // cards above keep: the badge is all a hovered row shows.
                trailing
            }
            // No horizontal inset: the art, the Open Steam button and the
            // footer chips all start at the popover's own padding, so the
            // column reads as one edge rather than the rows sitting in
            // from everything else.
            .padding(.vertical, Theme.Space.xs)
            .contentShape(Theme.innerShape)
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
        .contextMenu {
            // One-shot: swap the renderer and launch now. The launch path
            // restages the tree (or restarts, if the engine or sync must
            // change) before the game starts.
            Menu("Run with…") {
                ForEach(renderers, id: \.self) { renderer in
                    Button(renderer.label) { runWith(renderer) }
                }
            }
            Divider()
            // The pin stays listed when the machine no longer offers it, so
            // the menu shows what the game is set to rather than a blank.
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
    }

    /// The line under the name: what the client is doing with the game, or
    /// what its next launch will do. VoiceOver reads it as the row's value.
    private var status: (line: Text, isWarning: Bool)? {
        if let launchDetail {
            // The client's own words for its launch phase.
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
            // Pinned to a renderer the running client did not boot with: the
            // launch path restages it (or restarts, if the engine or sync must
            // change). Better said before the click than after.
            return (Text("\(restartFor.label) · set when it launches"), false)
        }
        return nil
    }

    /// The press is the app's claim to the activation right, and the game's
    /// window is what it will be spent on a minute later. The popover itself
    /// is a non-activating panel — it must stay one, or every click in it
    /// would pull focus off whatever the user was doing — so the press says
    /// so explicitly instead.
    private func launch() {
        ActivationPolicy.claimRightForALaunch()
        Task(name: "Launch \(game.name)") { await supervisor.launch(game) }
    }

    /// Swap to this renderer and launch immediately (context menu).
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

    /// What the pin menu reads and writes.
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

    /// The launch affordance (``PlayBadge``); the spinner stands in for it
    /// for the length of a launch.
    private var trailing: some View {
        PlayBadge(isBusy: isLaunching || launchDetail != nil, isHovered: isHovered)
    }
}

// MARK: - Quick Launch

/// The Windows programs the user handed to Sevoflurane, in the games'
/// column: they launch the same way, so they read as more of the same list.
private struct QuickLaunchPrograms: View {
    let quickLaunch: QuickLaunchStore
    /// The launch under way, which a program's row reads its status from as
    /// a game's does (``SteamWebHost/beginProgramLaunch(appID:)``).
    let activeLaunch: SteamWebHost.GameLaunch?
    /// The renderers the machine offers a program right now (``GraphicsStore/menuRenderers``).
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

/// One adopted program: its own icon, its name, and a press that starts
/// it through the daemon. It reads as a game's row does, Play badge and
/// status line included: in the same column, anything that looks different
/// reads as something that does not play.
private struct ProgramRow: View {
    let entry: AdoptedPrograms.Entry
    let icon: NSImage?
    let quickLaunch: QuickLaunchStore
    /// What its launch is doing now; `nil` outside one.
    let launchDetail: String?
    /// Its launch request is with the helper, which a first HoYoverse launch
    /// keeps for a quarter of a minute while it makes the companion prefix.
    let isLaunching: Bool
    /// The renderers the machine offers right now (``GraphicsStore/menuRenderers``).
    let renderers: [Renderer]
    @State private var isHovered = false
    @State private var dockBundle: URL?

    var body: some View {
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
        .task(id: entry.id) { dockBundle = await Self.readDockBundle(entry.id) }
        .contextMenu {
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
            Button("Show in Finder") { quickLaunch.showInFinder(entry) }
            Button("Remove") { quickLaunch.remove(entry) }
            Divider()
            GameSettingsItem(id: entry.id, name: entry.name)
        }
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

/// Keeps the game's own bundle in the Dock, where a click starts it through
/// the app and the running game lights the same tile. Offered once a launch
/// has built the bundle.
private struct KeepInDockItem: View {
    let bundle: URL?

    var body: some View {
        if let bundle {
            Button("Keep in Dock") { DockTiles.keep(bundle) }
        }
    }
}

/// A row with a bundle drags out as that bundle, for dropping on the Dock.
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

/// The line that adds one, hung under the last row in a smaller hand: it
/// belongs to the list above it, and an empty Quick Launch is what it is for.
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
            // The game row above ends in its own `xs` of padding and the
            // popover's `sm` stack spacing follows below, so this evens the
            // gap on both sides of the line.
            .padding(.top, Theme.Space.xs)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

/// The context-menu way into a game's own page in Settings › Games, where
/// what the menu above it sets is one of many things.
private struct GameSettingsItem: View {
    let id: Int
    let name: String

    var body: some View {
        Button("Game Settings…") { Self.open(id: id, name: name) }
    }

    static func open(id: Int, name: String) {
        (NSApp.delegate as? AppDelegate)?.showGameSettings(id: id, name: name)
    }
}
