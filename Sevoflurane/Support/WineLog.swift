import Foundation

/// Where Wine's own stderr goes for every managed launch — the client, a
/// windowed program, and every game the client spawns, since they inherit
/// the descriptor.
///
/// The default channels are ``levelZero``: errors, always on,
/// because a game that exits in two seconds leaves nothing else behind and
/// `WINEDEBUG=-all` silences `err` along with everything else. ``levelOne``
/// is the diagnostics switch, which adds the channels whose cost is a line
/// per event rather than a line per fault.
///
/// `sevo bottle config wine-debug +seh,+loaddll` sets the channels for the
/// next client start; `sevo logs --wine` reads the trail.
nonisolated enum WineLog {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Sevoflurane-wine.log")

    /// The `WINEDEBUG` a managed launch carries.
    static var channels: String {
        Preferences.shared.string(forKey: channelsKey) ?? levelZero
    }

    /// `nil` returns to the always-on default.
    static func setChannels(_ channels: String?) {
        if let channels, channels != levelZero {
            Preferences.shared.set(channels, forKey: channelsKey)
        } else {
            Preferences.shared.removeObject(forKey: channelsKey)
        }
    }

    /// Always on: every channel's errors — which is where Wine's unhandled
    /// exception record lands — and the process id on every line, since the
    /// client, its games and the prefix's own daemons all write to the one
    /// file. `err+all` costs a line at a fault and nothing while a game runs.
    static let levelZero = "err+all,+pid"

    /// What the diagnostics switch adds: exceptions as they are dispatched,
    /// which carries Steam's and a game's own `OutputDebugString` output but
    /// also every C++ throw a game makes, and every library load, which
    /// separates a game that failed to resolve an import from one that
    /// started and then died. Tens of thousands of lines per game run, so it
    /// is a choice rather than the default.
    static let levelOne = "err+all,+pid,+seh,+loaddll"

    private static let channelsKey = "wineDebug"

    /// Whether anything beyond the always-on default is on.
    static var isDiagnosing: Bool { channels != levelZero }

    static func setDiagnosing(_ on: Bool) {
        setChannels(on ? levelOne : nil)
    }

    /// `on (<channels>)` or `off (<channels>)` — off still names what the
    /// log keeps, which is not nothing.
    static var summary: String {
        "\(isDiagnosing ? "on" : "off") (\(channels))"
    }

    /// A handle appending to the log, after a header naming what is being
    /// launched. The file is rotated once past ``rotateOverBytes`` so a
    /// verbose channel left on for a week cannot fill the disk unbounded.
    /// Rotation copies and truncates rather than renaming: services.exe and
    /// winedevice.exe hold the file open from prefix boot, and a renamed
    /// inode would keep taking their output while readers watched the new
    /// file.
    static func handle(labeled label: String) -> FileHandle? {
        let manager = FileManager.default
        rotateIfLarge()
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? handle.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: .now)
        handle.write(Data("==== \(stamp) \(label) (WINEDEBUG=\(channels))\n".utf8))
        return handle
    }

    private static let rotateOverBytes = 20_000_000

    private static func rotateIfLarge() {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
              size > rotateOverBytes else { return }
        let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? manager.removeItem(at: old)
        try? manager.copyItem(at: fileURL, to: old)
        try? FileHandle(forWritingTo: fileURL).truncate(atOffset: 0)
    }
}
