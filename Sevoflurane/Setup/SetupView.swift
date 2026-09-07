import SwiftUI

/// The first-run assistant. Zero questions on the happy path: every step has
/// a detected default, and
/// the user only chooses when the choice costs money (CrossOver) or is
/// genuinely ambiguous.
struct SetupView: View {
    let provisioner: Provisioner
    let onFinished: () -> Void
    /// Reports whether Steam is sitting at its sign-in window, so the final
    /// button can say what clicking it will actually show.
    var signInPending: () -> Bool = { false }
    /// Fired once when provisioning completes, so the app can start the
    /// client behind the wizard — by the last page the window is already
    /// loaded and the finish button shows it instantly.
    var onProvisioned: () -> Void = {}
    /// Where the graphics step's store comes from. A simulated run supplies
    /// one with no engine behind it, which is what lets that step be walked
    /// at all: without it a dry run has to skip past it.
    var makeGraphics: (() -> GraphicsStore)?

    enum Step: String, CaseIterable {
        case welcome
        case engine
        case bottle
        case steam
        case graphics
        case options
        case done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .engine: "Choose an engine"
            case .bottle: "Choose a Steam"
            case .steam: "Installing Steam"
            case .graphics: "DirectX 12 games"
            case .options: "Preferences"
            case .done: "Ready to play"
            }
        }
    }

    private enum EngineChoice {
        case builtIn
        case crossover
    }

    @State private var step: Step
    @State private var openAtLogin = true
    @State private var connectAgents = false
    @State private var engineChoice: EngineChoice = .builtIn
    /// The bottle to adopt, or `nil` to build a fresh one.
    @State private var bottleChoice: String?
    @State private var newBottleName = SteamBottle.defaultName

    /// A real run always opens on the welcome. The gallery draws every step at
    /// once, and each tile starts on the one it is there to show.
    init(
        provisioner: Provisioner,
        startingAt step: Step = .welcome,
        signInPending: @escaping () -> Bool = { false },
        onProvisioned: @escaping () -> Void = {},
        makeGraphics: (() -> GraphicsStore)? = nil,
        onFinished: @escaping () -> Void,
    ) {
        self.provisioner = provisioner
        self.signInPending = signInPending
        self.onProvisioned = onProvisioned
        self.makeGraphics = makeGraphics
        self.onFinished = onFinished
        _step = State(initialValue: step)
        // Opening straight onto the graphics step skips the transition that
        // would otherwise build the store, so build it here instead.
        _graphicsStore = State(initialValue: step == .graphics ? makeGraphics?() : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 44)
                .padding(.top, 28)
            footer
                .padding(.horizontal, 44)
                .padding(.top, 16)
                .padding(.bottom, 28)
        }
        .frame(width: 680, height: step == .graphics ? 640 : 500)
        .task { await provisioner.refreshDetection() }
        .onChange(of: provisioner.activity) { _, activity in
            if activity == .done { onProvisioned() }
        }
        .overlay(alignment: .topTrailing) {
            if provisioner.isDryRun { demoBadge }
        }
    }

    /// Marks a simulated run (`SetupDryRun.swift`) so a screenshot can never
    /// be mistaken for a real provisioning pass.
    private var demoBadge: some View {
        Text("DEMO")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.orange.opacity(0.15)))
            .padding(10)
            .help("Simulated setup — nothing on this Mac changes.")
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .engine: engine
        case .bottle: bottle
        case .steam: steam
        case .graphics: graphics
        case .options: options
        case .done: done
        }
    }

    /// The managed engine can't ship Apple's D3DMetal, so this step offers to
    /// fetch it — in-app, through Apple's own sign-in. Skippable: DXMT is the
    /// default renderer and covers most DirectX 11 titles. CrossOver brings
    /// its own D3DMetal, so this step never shows for it.
    @State private var graphicsStore: GraphicsStore?
    @State private var gptk = GPTkDownload()

    private var usesManagedEngine: Bool {
        if case .managed = Engine.active { true } else { false }
    }

    @ViewBuilder private var graphics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DirectX 12 games (optional)")
                .font(.system(size: 24, weight: .bold))
            Text("Apple's Game Porting Toolkit adds D3DMetal — the only renderer "
                + "that runs DirectX 12, which most modern games use. It's a free "
                + "download from Apple; the built-in engine can't include it directly.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GPTkDownloadPanel(
                download: gptk,
                install: { url in await graphicsStore?.installD3DMetal(from: url) },
                isSimulated: provisioner.isDryRun,
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to Sevoflurane")
                .font(.system(size: 26, weight: .bold))
            Text("Your Steam library, native on the Mac. Setup takes a few "
                + "minutes and runs by itself — you'll sign in to Steam once at the end.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var engine: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One thing to install")
                .font(.system(size: 24, weight: .bold))
            Text("Steam's games are built for Windows. To play them, your Mac "
                + "needs a translator that turns what a game asks Windows for "
                + "into something macOS understands. Which translator is the "
                + "only decision in this setup.")
                .foregroundStyle(.secondary)
            if let crossover = provisioner.detection?.crossover, crossover.trialExpired {
                Text("CrossOver \(crossover.version) is installed, but its trial has ended. "
                    + "License it at codeweavers.com, or use the built-in engine.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            engineOption(
                .builtIn,
                title: "Built-in engine — free, about 250 MB (recommended)",
                detail: "A one-time download. This is Wine, the open-source "
                    + "Windows translator, and it runs most games well.",
            )
            engineOption(.crossover, title: crossOverTitle, detail: crossOverDetail)
            // Shown rather than disclosed: the step has room for it, and a
            // chevron the size of a chevron is a poor place to keep the one
            // paragraph that answers "why would I pay for this?".
            VStack(alignment: .leading, spacing: 4) {
                Text("Why pay for CrossOver?").font(.callout.weight(.semibold))
                Text("CodeWeavers pays the developers who build Wine — the "
                    + "translator under both options — so CrossOver gets their "
                    + "Steam and per-game fixes months before the free version "
                    + "does. The built-in engine is the same project without "
                    + "those extras, and it is enough for most games. You can "
                    + "switch later in Settings without redoing this setup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.5)),
            )
            if engineChoice == .crossover {
                Link(
                    "Get CrossOver at codeweavers.com",
                    destination: URL(string: "https://www.codeweavers.com/crossover")!,
                )
                Button("Check again") {
                    Task { await provisioner.refreshDetection() }
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the CrossOver option is worth saying: a licensed copy on the
    /// machine is a free choice, and quoting a price at someone who has
    /// already paid reads as a sales pitch.
    private var crossOverTitle: String {
        guard let crossover = provisioner.detection?.crossover else {
            return "Use CrossOver ($74, 14-day free trial)"
        }
        if crossover.licensed { return "Use CrossOver \(crossover.version) (already licensed)" }
        if crossover.trialExpired { return "Use CrossOver ($74 — this Mac's trial has ended)" }
        return "Use CrossOver \(crossover.version) (trial, $74 to keep)"
    }

    private var crossOverDetail: String {
        "The paid version of the same translator, with fixes for specific "
            + "games and a support team behind it."
    }

    private func engineOption(
        _ choice: EngineChoice, title: String, detail: String,
    ) -> some View {
        Button {
            engineChoice = choice
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: engineChoice == choice
                    ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(engineChoice == choice ? Color.accentColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(engineChoice == choice
                        ? Color.accentColor.opacity(0.08) : Color.clear),
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// The Steam installations already on the machine. Only ever shown when
    /// the answer is genuinely ambiguous — one bottle named the way we would
    /// name it needs no question.
    private var bottleCandidates: [SetupDetection.Bottle] {
        provisioner.detection?.steamBottles ?? []
    }

    private var needsBottleChoice: Bool {
        bottleCandidates.count > 1
            || (bottleCandidates.first.map { $0.name != SteamBottle.defaultName } ?? false)
    }

    private var bottle: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which Steam?")
                .font(.system(size: 24, weight: .bold))
            Text("This Mac already has Steam installed more than once. Each "
                + "copy sits in its own pretend Windows drive — a bottle — "
                + "with its own games and settings. Pick one and its games "
                + "stay exactly where they are; start a new one and Steam "
                + "downloads from scratch.")
                .foregroundStyle(.secondary)
            Picker("", selection: $bottleChoice) {
                ForEach(bottleCandidates, id: \.name) { candidate in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.name)
                        Text((candidate.url.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(String?.some(candidate.name))
                }
                Text("Start a new one")
                    .tag(String?.none)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if bottleChoice == nil { newBottleField }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var newBottleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Bottle name", text: $newBottleName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            if let objection = newBottleObjection {
                Text(objection).font(.caption).foregroundStyle(.orange)
            } else {
                Text("The new bottle's folder takes this name, alongside the others.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 20)
    }

    /// Why the typed name cannot be used, if it cannot. A bottle is a
    /// directory, and one that already exists belongs to whatever put it
    /// there — installing Steam into it is not ours to decide.
    private var newBottleObjection: String? {
        let name = newBottleName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give the bottle a name." }
        if name.contains("/") || name.contains(":") {
            return "Use a name without / or : in it."
        }
        if provisioner.detection?.bottles.contains(where: { $0.name == name }) == true {
            return "There is already a bottle named “\(name)”. Pick another name."
        }
        return nil
    }

    /// Whether the bottle being set up already carries a Steam install —
    /// adoption checks and updates a client instead of downloading one, and
    /// telling someone their installed Steam is being downloaded is a lie
    /// they will watch for minutes.
    private var isAdoptingSteam: Bool {
        provisioner.detection?.steamBottles.contains { $0.name == SteamBottle.name } == true
    }

    private var steam: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isAdoptingSteam ? "Getting Steam ready" : "Setting up Steam")
                .font(.system(size: 24, weight: .bold))
            Text(isAdoptingSteam
                ? "Checking the Steam already installed here and bringing it up "
                + "to date. An old copy can take a few minutes to catch up."
                : "Downloading and installing the Steam client. This is the longest "
                + "step — a few minutes on most connections.")
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        switch provisioner.activity {
                        case let .working(phase):
                            ProgressView().controlSize(.small)
                            Text(phase)
                        case let .failed(reason):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Setup stopped before Steam was installed.")
                                Text(reason)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        case .done:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Steam is ready.")
                        case .idle:
                            Text("Starting…")
                        }
                        Spacer()
                        if case .failed = provisioner.activity {
                            Button("Try Again") {
                                Task { await provisioner.retry() }
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    if case .working = provisioner.activity,
                        let stage = provisioner.stage
                    {
                        ProgressView(value: overallProgress(stage))
                        Text(stageCaption(stage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            Text(hasFailed
                ? "Trying again keeps whatever already downloaded, so a second "
                + "attempt is usually much shorter than the first."
                : "You can close this window — setup carries on in the menu bar, "
                + "and picks up where it left off if it is interrupted.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The overall bar: completed stages plus the current stage's own
    /// fraction, over the fixed sequence length.
    private func overallProgress(_ stage: Provisioner.Stage) -> Double {
        (Double(stage.index - 1) + (provisioner.stageFraction ?? 0))
            / Double(Provisioner.Stage.count)
    }

    private func stageCaption(_ stage: Provisioner.Stage) -> String {
        var caption = "Step \(stage.index) of \(Provisioner.Stage.count)"
        if let fraction = provisioner.stageFraction {
            caption += " — \(Int(fraction * 100))% downloaded"
        }
        return caption
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A few preferences")
                .font(.system(size: 24, weight: .bold))
            Text("All of these can be changed later.")
                .foregroundStyle(.secondary)
            Toggle(isOn: $openAtLogin) {
                VStack(alignment: .leading) {
                    Text("Open at login").font(.headline)
                    Text("Sevoflurane starts in the menu bar. No windows until you ask.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                // The label takes the width so the switch sits at the window's
                // trailing edge, where every other switch in the app sits.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            Toggle(isOn: $connectAgents) {
                VStack(alignment: .leading) {
                    Text("Install the sevo command").font(.headline)
                    Text("Puts the sevo command-line tool on your PATH and "
                        + "connects your AI assistants — Claude, Codex, Hermes — "
                        + "to Steam over MCP where they're installed. Asks for "
                        + "an administrator password once; every connection has "
                        + "its own switch in Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var done: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Ready to play")
                .font(.system(size: 26, weight: .bold))
            doneCaption
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Where to find the app once setup closes, with the menu-bar glyph itself set into the
    /// sentence so the eye has something to match against the menu bar.
    private var doneCaption: Text {
        let icon = Image(nsImage: MenuBarIcon.image(badged: false))
        if signInPending() {
            return Text(
                "Your library lives in the menu bar, behind \(icon) at the top right. Steam is ready — sign in and your library opens.",
            )
        }
        return Text("Your library lives in the menu bar, behind \(icon) at the top right.")
    }

    private var hasFailed: Bool {
        if case .failed = provisioner.activity { true } else { false }
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch step {
            case .welcome:
                Button("Get Started") { advanceFromWelcome() }
                    .keyboardShortcut(.defaultAction)
            case .engine:
                Button("Continue") { advanceFromEngine() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(engineChoice == .crossover
                        && provisioner.detection?.usableCrossOver == nil)
            case .bottle:
                Button("Continue") {
                    SteamBottle.choose(
                        bottleChoice ?? newBottleName.trimmingCharacters(in: .whitespaces),
                    )
                    beginProvisioning()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bottleChoice == nil && newBottleObjection != nil)
            case .steam:
                Button("Continue") { advanceFromSteam() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(provisioner.activity != .done)
            case .graphics:
                Button(graphicsStore?.d3dMetalVersions.isEmpty == false
                    ? "Continue" : "Skip for now") { step = .options }
                    .keyboardShortcut(.defaultAction)
                    .disabled(gptk.isBusy)
            case .options:
                Button("Continue") {
                    provisioner.setOpenAtLogin(openAtLogin)
                    if connectAgents, !provisioner.isDryRun {
                        Task {
                            if let failure = await AgentIntegration.install() {
                                EventLog.shared.log(.app, "sevo CLI install: \(failure)")
                            }
                        }
                    }
                    step = .done
                }
                .keyboardShortcut(.defaultAction)
            case .done:
                Button(signInPending() ? "Log In to Steam" : "Open My Library") {
                    onFinished()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    private func advanceFromWelcome() {
        guard provisioner.detection?.usableCrossOver != nil else {
            step = .engine
            return
        }
        advanceFromEngine()
    }

    private func advanceFromEngine() {
        guard needsBottleChoice else {
            beginProvisioning()
            return
        }
        bottleChoice = bottleCandidates
            .first { $0.name == SteamBottle.name }?.name ?? bottleCandidates.first?.name
        step = .bottle
    }

    private func beginProvisioning() {
        step = .steam
        if provisioner.activity == .idle {
            Task { await provisioner.provisionAndConfigure() }
        }
    }

    /// After provisioning: the managed engine needs D3DMetal added for DX12,
    /// so offer it; CrossOver brings its own, so go straight to preferences.
    private func advanceFromSteam() {
        guard usesManagedEngine, makeGraphics != nil || !provisioner.isDryRun else {
            step = .options
            return
        }
        if graphicsStore == nil {
            graphicsStore = makeGraphics?() ?? GraphicsStore()
        }
        step = .graphics
    }
}
