import AppKit
import SwiftUI

/// The menu-bar extra: what Steam's own tray menu shows — recent games first,
/// then the client controls.
struct MenuBarView: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor

    private var healthColor: Color {
        switch supervisor.health {
        case .healthy: .green
        case .starting, .degraded, .restarting: .yellow
        case .gaveUp: .red
        case .paused: .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cloud.fill")
                    .foregroundStyle(.yellow)
                Text("Sevoflurane").font(.headline)
            }

            Text(host.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(healthColor).frame(width: 7, height: 7)
                Text(supervisor.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let event = EventLog.shared.latest {
                Text("\(event.date, format: .dateTime.hour().minute()) \(event.message)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            if !host.recentGames.isEmpty {
                Divider()
                Text("Recent Games")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(host.recentGames) { game in
                    Button {
                        host.launchGame(game)
                    } label: {
                        HStack(spacing: 8) {
                            AsyncImage(url: game.artURL) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Color.secondary.opacity(0.2)
                            }
                            .frame(width: 24, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(game.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button("Open Steam") { host.showSteam() }
                .keyboardShortcut("o")
            Button("Reload UI") { host.reload() }
            Button("Restart Steam Client") { supervisor.restartNow() }
            Button(supervisor.health == .paused ? "Resume Auto-Restart" : "Pause Auto-Restart") {
                supervisor.togglePaused()
            }
            Button("Open Log") { NSWorkspace.shared.open(EventLog.fileURL) }
            Button("Quit Sevoflurane") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .onAppear { host.refreshRecentGames() }
    }
}
