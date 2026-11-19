import Foundation
import Observation

/// Debug mode as the app holds it: a session that starts off at every launch.
///
/// The app half (synchronous log flushing, a window inventory on every adoption
/// and close) applies at once; the engine half is ``DebugMode``'s env file,
/// read at a program's start, so it reaches Steam only after a restart.
@MainActor
@Observable
final class DebugModeSwitch {
    static let shared = DebugModeSwitch()

    private(set) var isOn = false

    /// Turns the mode on or off, answering whether anything changed.
    @discardableResult
    func set(_ on: Bool) -> Bool {
        guard on != isOn else { return false }
        isOn = on
        EventLog.flushMode = on ? .synchronous : .asynchronous
        if on {
            DebugMode.turnOn(prefix: SteamBottle.root)
            EventLog.shared.log(
                .app,
                "debug mode on — every library load, the renderer's log and the engine's "
                    + "frame logs, from Steam's next start",
            )
        } else {
            DebugMode.turnOff(prefix: SteamBottle.root)
            EventLog.shared.log(.app, "debug mode off — from Steam's next start")
        }
        return true
    }

    /// Deletes an env file the last session left behind. Called before anything
    /// can start a bottle process.
    func clearStaleFile() {
        guard DebugMode.clearStale(prefix: SteamBottle.root) else { return }
        EventLog.shared.log(.app, "debug mode was left on last time — turned it off")
    }

    /// Takes the engine half off on the way out, so a relaunch or `sevo run` is
    /// not left verbose.
    func endSession() {
        DebugMode.turnOff(prefix: SteamBottle.root)
    }

    /// The footer chip's tooltip: the three logs the mode grows and their
    /// sizes.
    var summary: String {
        var lines = [InterfaceCopy.localized("Debug mode is on. Logs grow.")]
        lines += Self.logs.map { name, url in
            "\(name): \(Self.size(of: url))"
        }
        if Engine.active.isCrossOver {
            lines.append(InterfaceCopy.localized("CrossOver skips the engine logs. The app logs are on."))
        } else {
            lines.append(InterfaceCopy.localized("Restart Steam to apply it to the client and its games."))
        }
        return lines.joined(separator: "\n")
    }

    private static var logs: [(name: String, url: URL)] {
        [
            ("Sevoflurane.log", EventLog.fileURL),
            ("Sevoflurane-wine.log", WineLog.fileURL),
            ("Sevoflurane-windows.log", WineChronicle.url),
        ]
    }

    private static func size(of url: URL) -> String {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return InterfaceCopy.localized("not written yet")
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The control port's debug surface: `GET /debug` reports, `POST /debug/on`
    /// and `POST /debug/off` set.
    func handleControl(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "POST" {
            set(request.path.hasSuffix("/on"))
        }
        let payload: [String: Any] = [
            "on": isOn,
            "file": DebugMode.envURL(prefix: SteamBottle.root).path,
            "note": isOn
                ? "the app half is on; the engine half applies at Steam's next start — restart Steam"
                : "the app half is off and the env file is gone",
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys],
        )) ?? Data("{}".utf8)
        return .ok(data, type: "application/json")
    }
}
