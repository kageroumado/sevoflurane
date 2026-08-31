import SwiftUI

/// The first-run assistant (`Mockups/onboarding.html` is the design source).
/// Zero questions on the happy path: every step has a detected default, and
/// the user only chooses when the choice costs money (CrossOver) or is
/// genuinely ambiguous.
struct SetupView: View {
    @Bindable var provisioner: Provisioner
    let onFinished: () -> Void
    /// Reports whether Steam is sitting at its sign-in window, so the final
    /// button can say what clicking it will actually show.
    var signInPending: () -> Bool = { false }
    /// Fired once when provisioning completes, so the app can start the
    /// client behind the wizard — by the last page the window is already
    /// loaded and the finish button shows it instantly.
    var onProvisioned: () -> Void = {}

    private enum Step {
        case welcome
        case engine
        case bottle
        case steam
        case graphics
        case options
        case done
    }

    private enum EngineChoice {
        case builtIn
        case crossover
    }

    @State private var step: Step = .welcome
    @State private var openAtLogin = true
    @State private var engineChoice: EngineChoice = .builtIn
    /// The bottle to adopt, or `nil` to build a fresh one.
    @State private var bottleChoice: String?
    @State private var newBottleName = SteamBottle.defaultName

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
            if provisioner.isDryRun { dryRunBadge }
        }
    }

    /// Marks a harness run (`SetupDryRun.swift`) so a screenshot can never be
    /// mistaken for a real provisioning pass.
    private var dryRunBadge: some View {
        Text("DRY RUN")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.orange.opacity(0.15)))
            .padding(10)
            .help("Simulated onboarding — nothing on this machine changes.")
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
            Text("Sevoflurane needs a compatibility layer to run Steam's Windows catalog on your Mac.")
                .foregroundStyle(.secondary)
            if let crossover = provisioner.detection?.crossover, crossover.trialExpired {
                Text("CrossOver \(crossover.version) is installed, but its trial has ended. "
                    + "License it at codeweavers.com, or use the built-in engine.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            engineOption(
                .builtIn,
                title: "Install the built-in engine (free, ~250 MB)",
                detail: "Recommended. Downloads once; games render through Metal.",
            )
            engineOption(.crossover, title: crossOverTitle, detail: crossOverDetail)
            // Shown rather than disclosed: the step has room for it, and a
            // chevron the size of a chevron is a poor place to keep the one
            // paragraph that answers "why would I pay for this?".
            VStack(alignment: .leading, spacing: 4) {
                Text("Why CrossOver?").font(.callout.weight(.semibold))
                Text("CodeWeavers employs the Wine developers; CrossOver carries "
                    + "Steam- and game-specific fixes months before they reach "
                    + "open-source Wine, and buying it funds Wine itself. The "
                    + "built-in engine runs the same core code and is fine for "
                    + "most titles — you can switch later in Settings without "
                    + "redoing setup.")
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
        "Commercial engine by CodeWeavers with better game compatibility and support."
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
            Text("This Mac already has Steam in more than one Windows bottle. "
                + "Pick one and your games stay where they are; build a new "
                + "one and Steam downloads again from scratch.")
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
                Text("Build a new bottle")
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
                Text("Its folder is named this, next to your other bottles.")
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
            return "A bottle name cannot contain / or :."
        }
        if provisioner.detection?.bottles.contains(where: { $0.name == name }) == true {
            return "A bottle named “\(name)” already exists."
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
                ? "Checking the client in this bottle and bringing it up to date. "
                + "An old install can take a few minutes to catch up."
                : "Downloading and installing the Steam client. This is the longest "
                + "step — a few minutes on most connections.")
                .foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        switch provisioner.activity {
                        case let .working(phase):
                            ProgressView().controlSize(.small)
                            Text(phase)
                        case let .failed(reason):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(reason).font(.callout)
                        case .done:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Steam is ready.")
                        case .idle:
                            Text("Ready to start.")
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
            Text("You can close this window — setup continues in the menu bar and "
                + "picks up where it left off if interrupted.")
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
            (
                Text("Your library lives in the menu bar, behind ")
                    + Text(Image(nsImage: MenuBarIcon.image(badged: false)))
                    + Text(signInPending()
                        ? " at the top right. Steam is ready — sign in and your library opens."
                        : " at the top right.")
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
                Button("Finish") {
                    provisioner.setOpenAtLogin(openAtLogin)
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
        guard usesManagedEngine, !provisioner.isDryRun else {
            step = .options
            return
        }
        if graphicsStore == nil { graphicsStore = GraphicsStore.live() }
        step = .graphics
    }
}
