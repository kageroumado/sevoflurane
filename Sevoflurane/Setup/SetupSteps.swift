import Propofol
import SwiftUI

// The pages of the first-run assistant, one view each. ``SetupView`` owns the
// step and the answers; a page draws them and reports a change through its
// bindings.

/// The engine the assistant is asked to install.
enum SetupEngineChoice {
    case builtIn
    case crossover
}

struct SetupWelcomeStep: View {
    /// The website's feature highlights, word for word, so the first page and
    /// the page that sent someone here promise the same things.
    private static let highlights: [SetupHighlight] = [
        SetupHighlight(
            icon: "arrow.up.left.and.arrow.down.right",
            title: "Optional upscaling",
            caption: "Old games render small. Sevoflurane can upscale the picture past the game\u{2019}s own "
                + "resolution, with filters for 3D games and for 2D anime art.",
        ),
        SetupHighlight(
            icon: "macwindow",
            title: "Windows that behave",
            caption: "Every game is a real Mac window. Fixed-size games, even old ones that never allowed "
                + "it, become resizable and go native full screen.",
        ),
        SetupHighlight(
            icon: "cube.transparent",
            title: "DirectX 12 support",
            caption: "Games run through Dormison, Sevoflurane\u{2019}s own build of Wine with DirectX 12 "
                + "support and fixes for the games themselves.",
        ),
        SetupHighlight(
            icon: "gamecontroller",
            title: "Game Mode, automatically",
            caption: "Each game launches as its own app. When it fills the screen, macOS engages Game Mode "
                + "on its own. Nothing to toggle.",
        ),
        SetupHighlight(
            icon: "display",
            title: "Steam, always Retina",
            caption: "Steam\u{2019}s interface runs in native WKWebViews at the screen\u{2019}s real scale, "
                + "with its menus in the menu bar and Mac notifications.",
        ),
        SetupHighlight(
            icon: "folder",
            title: "Not just Steam",
            caption: "Open any Windows program from Finder. Sevoflurane tells a game from an installer, "
                + "runs or installs it, and gives it the same treatment.",
        ),
    ]

    var body: some View {
        SetupHero(
            title: "Sevoflurane",
            caption: Text("Windows games on macOS"),
        ) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
        } content: {
            Grid(
                alignment: .topLeading,
                horizontalSpacing: Theme.Space.xl,
                verticalSpacing: Theme.Space.lg,
            ) {
                ForEach(0 ..< Self.highlights.count / 2, id: \.self) { row in
                    GridRow {
                        SetupHighlightView(highlight: Self.highlights[row * 2])
                        SetupHighlightView(highlight: Self.highlights[row * 2 + 1])
                    }
                }
            }
        }
    }
}

/// One of the welcome page's feature highlights.
struct SetupHighlight {
    let icon: String
    let title: String
    let caption: String
}

private struct SetupHighlightView: View {
    let highlight: SetupHighlight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Image(systemName: highlight.icon)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title)
                    .font(.callout.weight(.semibold))
                Text(highlight.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SetupEngineStep: View {
    let provisioner: Provisioner
    @Binding var choice: SetupEngineChoice
    let bundledEngine: URL?

    private var crossover: SetupDetection.CrossOver? {
        provisioner.detection?.crossover
    }

    var body: some View {
        SetupPage(
            glyph: "engine.combustion",
            title: "Engine",
            subtitle: "A Wine engine runs Windows games on your Mac.",
        ) {
            SetupList {
                SetupChoiceRow(
                    icon: "shippingbox",
                    title: "Dormison",
                    caption: dormisonCaption,
                    value: "Free",
                    isSelected: choice == .builtIn,
                ) { choice = .builtIn }
                SetupChoiceRow(
                    icon: "wineglass",
                    title: crossover.map { "CrossOver \($0.version)" } ?? "CrossOver",
                    caption: "CodeWeavers' paid engine, with per-game fixes and a support team.",
                    value: crossOverValue,
                    isSelected: choice == .crossover,
                ) { choice = .crossover }
            }
            if let crossover, crossover.trialExpired {
                SetupFootnote(
                    text: "The CrossOver \(crossover.version) trial on this Mac has ended. "
                        + "License it at codeweavers.com, or use Dormison.",
                    style: .init(.orange),
                )
            }
            SetupFootnote(
                text: "CodeWeavers develops Wine, and both engines are built on it. "
                    + "Switch engines later in Settings.",
            )
        }
    }

    /// Where Dormison comes from: the download, the tarball this copy of the
    /// app ships with, or a file someone chose.
    private var dormisonCaption: String {
        if let tarball = provisioner.engineTarball {
            return "Installs from \(tarball.lastPathComponent)."
        }
        if let bundledEngine {
            return "\(Engine.managedDisplayName(EngineInstaller.versionName(of: bundledEngine))) "
                + "comes with this copy. Nothing to download."
        }
        return "Sevoflurane's own engine: DirectX 12 through Apple's toolkit, and game upscaling."
    }

    /// CodeWeavers sets the price; what is worth saying is the license state
    /// of the copy on this Mac.
    private var crossOverValue: String {
        guard let crossover else { return "14-day trial" }
        if crossover.licensed { return "Licensed" }
        return crossover.trialExpired ? "Trial ended" : "Trial"
    }
}

struct SetupBottleStep: View {
    let candidates: [SetupDetection.Bottle]
    @Binding var choice: String?
    @Binding var newName: String
    let newNameObjection: String?
    @Binding var downloadEverything: Bool

    /// What the optional half of the catalog weighs, rounded the way its own
    /// rows are written.
    private static let optionalDownloadSize = "320 MB"

    var body: some View {
        SetupPage(
            glyph: "externaldrive",
            title: "Steam",
            subtitle: "Use a Steam already on this Mac, or start a new one.",
        ) {
            SetupList {
                ForEach(candidates, id: \.name) { candidate in
                    SetupChoiceRow(
                        icon: "folder",
                        title: candidate.name,
                        caption: (candidate.url.path as NSString).abbreviatingWithTildeInPath,
                        isSelected: choice == candidate.name,
                    ) { choice = candidate.name }
                }
                SetupChoiceRow(
                    icon: "plus.circle",
                    title: "Start a new one",
                    caption: "An empty bottle with a fresh Steam.",
                    isSelected: choice == nil,
                ) { choice = nil }
            }
            if choice == nil {
                SetupList {
                    SetupRow(
                        icon: "pencil",
                        title: "Name",
                        caption: newNameObjection,
                        captionStyle: .init(.orange),
                    ) {
                        TextField("Bottle name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                }
            }
            SetupList {
                SetupRow(
                    icon: "arrow.down.circle",
                    title: "Download everything",
                    caption: "The fonts and legacy runtimes games ask for.",
                ) {
                    Text(Self.optionalDownloadSize).foregroundStyle(.secondary)
                    Toggle("Download everything", isOn: $downloadEverything)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }
}

struct SetupInstallStep: View {
    let provisioner: Provisioner
    let isAdoptingSteam: Bool

    /// The provisioner's fixed sequence, by stage index.
    private static let stages: [(icon: String, title: String)] = [
        ("cpu", "Rosetta"),
        ("engine.combustion", "Game engine"),
        ("folder", "Steam's folder"),
        ("arrow.down.circle", "Steam installer"),
        ("gamecontroller", "Steam"),
        ("textformat", "Fonts and runtimes"),
    ]

    var body: some View {
        SetupPage(
            glyph: "arrow.down.circle",
            title: title,
            subtitle: subtitle,
        ) {
            SetupList {
                ForEach(Array(Self.stages.enumerated()), id: \.offset) { offset, stage in
                    SetupRow(icon: stage.icon, title: stage.title, caption: caption(forStage: offset + 1)) {
                        mark(forStage: offset + 1)
                    }
                }
            }
            if case let .failed(reason) = provisioner.activity {
                SetupFootnote(text: reason, style: .init(.orange))
            }
            SetupFootnote(text: closingNote)
        }
    }

    private var title: String {
        if provisioner.activity == .done { return "Steam is ready" }
        return isAdoptingSteam ? "Getting Steam ready" : "Setting up Steam"
    }

    private var subtitle: String {
        if provisioner.activity == .done { return "Continue to finish setting up." }
        return isAdoptingSteam
            ? "Checking the Steam installed here and updating it."
            : "Most connections take a few minutes."
    }

    private var currentStage: Int {
        if provisioner.activity == .done { return Self.stages.count + 1 }
        return provisioner.stage?.index ?? 0
    }

    private func caption(forStage index: Int) -> String? {
        guard index == currentStage, case let .working(phase) = provisioner.activity else { return nil }
        guard let fraction = provisioner.stageFraction else { return phase }
        return "\(phase) \(Int(fraction * 100))%"
    }

    @ViewBuilder
    private func mark(forStage index: Int) -> some View {
        if index < currentStage {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("Done")
        } else if index == currentStage {
            if case .failed = provisioner.activity {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Failed")
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var closingNote: String {
        guard case .failed = provisioner.activity else {
            return "Close this window any time. Setup carries on in the menu bar, "
                + "and resumes where it stopped."
        }
        if provisioner.engineInstallPending {
            return "The engine also installs from a file: dormison-r<N>.tar.xz and its "
                + ".sig, from the Dormison release."
        }
        return "A second try keeps what already downloaded."
    }
}

/// The managed engine cannot ship Apple's D3DMetal, so this step fetches it
/// in the app, through Apple's own sign-in. CrossOver brings its own, and
/// never sees this step.
struct SetupGraphicsStep: View {
    let download: GPTkDownload
    let store: GraphicsStore?
    let isSimulated: Bool

    var body: some View {
        SetupPage(
            glyph: "cube.transparent",
            title: "DirectX 12 games",
            subtitle: "Optional. Apple\u{2019}s D3DMetal, free with an Apple developer sign-in.",
        ) {
            GPTkDownloadPanel(
                download: download,
                install: { url in await store?.installD3DMetal(from: url, choosing: false) },
                isSimulated: isSimulated,
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.bottom, Theme.Space.lg)
        }
    }
}

struct SetupOptionsStep: View {
    @Binding var openAtLogin: Bool
    @Binding var installsCommand: Bool

    var body: some View {
        SetupPage(
            glyph: "switch.2",
            title: "Startup and automation",
            subtitle: "Both can change later, in Settings.",
        ) {
            SetupList {
                SetupRow(
                    icon: "power",
                    title: "Open at login",
                    caption: "Sevoflurane waits in the menu bar.",
                ) {
                    Toggle("Open at login", isOn: $openAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SetupRow(
                    icon: "terminal",
                    title: "Install the sevo command",
                    caption: "A command-line tool, and the way AI assistants reach Steam through MCP. "
                        + "Asks for an administrator password.",
                ) {
                    Toggle("Install the sevo command", isOn: $installsCommand)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }
}

struct SetupDoneStep: View {
    let window: SetupSteamWindow

    var body: some View {
        SetupHero(title: "Ready to play", caption: caption) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 88))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .frame(height: 112)
                .accessibilityHidden(true)
        } content: {
            EmptyView()
        }
    }

    /// Where to find the app once setup closes, with the menu-bar glyph set
    /// into the sentence so the eye has something to match against the menu bar.
    private var caption: Text {
        let icon = Image(nsImage: MenuBarIcon.image(badged: false))
        return switch window {
        case .signIn:
            Text("Your library lives in the menu bar, behind \(icon). Sign in to Steam and it opens.")
        case .library:
            Text("Your library lives in the menu bar, behind \(icon).")
        case .starting:
            Text("Your library lives in the menu bar, behind \(icon). Steam is starting; a first start takes a minute.")
        case let .helperDown(reason):
            Text(reason)
        }
    }
}

struct SetupSharingStep: View {
    var body: some View {
        SetupPage(
            glyph: "chart.bar.xaxis",
            title: "Help other Mac players",
            subtitle: "Share how each game ran, so everyone can see what plays well on which Mac.",
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(
                    "After a game closes, Sevoflurane sends its frame rate, resolution, engine and settings, "
                        + "with your Mac\u{2019}s model and chip. Nothing names you, your Mac or your account.",
                )
                .fixedSize(horizontal: false, vertical: true)
                Text("You can stop, or delete what you shared, in Settings \u{203A} General.")
                    .foregroundStyle(.secondary)
                SharedRunPreview()
            }
        }
    }
}
