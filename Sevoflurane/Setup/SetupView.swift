import SwiftUI

/// The first-run assistant (`Mockups/onboarding.html` is the design source).
/// Zero questions on the happy path: every step has a detected default, and
/// the user only chooses when the choice costs money (CrossOver) or is
/// genuinely ambiguous.
struct SetupView: View {
    @Bindable var provisioner: Provisioner
    let onFinished: () -> Void

    private enum Step {
        case welcome
        case engine
        case steam
        case options
        case done
    }

    @State private var step: Step = .welcome
    @State private var openAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 44)
                .padding(.top, 28)
            footer
                .padding(.horizontal, 44)
                .padding(.bottom, 28)
        }
        .frame(width: 680, height: 500)
        .task { await provisioner.refreshDetection() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .engine: engine
        case .steam: steam
        case .options: options
        case .done: done
        }
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
                    + "License it at codeweavers.com, or wait for the built-in engine.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Built-in engine — coming in a later beta").font(.headline)
                    Text("This build requires CrossOver (14-day free trial works). "
                        + "The free built-in engine is on the roadmap; CrossOver also "
                        + "carries game fixes months earlier and funds Wine development.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Link(
                "Get CrossOver at codeweavers.com",
                destination: URL(string: "https://www.codeweavers.com/crossover")!,
            )
            Button("Check again") {
                Task { await provisioner.refreshDetection() }
            }
        }
    }

    private var steam: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setting up Steam")
                .font(.system(size: 24, weight: .bold))
            Text("Downloading and installing the Steam client. This is the longest "
                + "step — a few minutes on most connections.")
                .foregroundStyle(.secondary)
            GroupBox {
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
                }
                .padding(8)
            }
            Text("You can close this window — setup continues in the menu bar and "
                + "picks up where it left off if interrupted.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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
            }
            .toggleStyle(.switch)
        }
    }

    private var done: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Ready to play")
                .font(.system(size: 26, weight: .bold))
            Text("Your library lives in the menu bar — the yellow glyph, top right. "
                + "Steam's sign-in window opens next if you aren't signed in yet.")
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
                Button("Continue") { advanceFromWelcome() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(provisioner.detection?.usableCrossOver == nil)
            case .steam:
                Button("Continue") { step = .options }
                    .keyboardShortcut(.defaultAction)
                    .disabled(provisioner.activity != .done)
            case .options:
                Button("Finish") {
                    provisioner.setOpenAtLogin(openAtLogin)
                    step = .done
                }
                .keyboardShortcut(.defaultAction)
            case .done:
                Button("Open My Library") { onFinished() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func advanceFromWelcome() {
        guard provisioner.detection?.usableCrossOver != nil else {
            step = .engine
            return
        }
        step = .steam
        if provisioner.activity == .idle {
            Task {
                await provisioner.provisionSteam()
                if case .done = provisioner.activity {
                    await provisioner.configureBottle(named: "Steam")
                }
            }
        }
    }
}

#Preview {
    SetupView(provisioner: Provisioner()) {}
}
