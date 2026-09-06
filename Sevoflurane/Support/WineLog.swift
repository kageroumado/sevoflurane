import Foundation

/// Where Wine's own stderr goes for every managed launch — the client, a
/// windowed program, and every game the client spawns, since they inherit
/// the descriptor. Silent by default: the launch environment carries
/// `WINEDEBUG=-all`, so only Wine's crash reports and whatever the
/// `wineDebug` preference switches on reach the file.
///
/// `sevo bottle config wine-debug +seh,+loaddll` sets the channels for the
/// next client start; `sevo logs --wine` reads the trail.
nonisolated enum WineLog {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Sevoflurane-wine.log")

    /// The `WINEDEBUG` a managed launch carries.
    static var channels: String {
        Preferences.shared.string(forKey: channelsKey) ?? quiet
    }

    /// `nil` returns to the quiet default.
    static func setChannels(_ channels: String?) {
        if let channels, channels != quiet {
            Preferences.shared.set(channels, forKey: channelsKey)
        } else {
            Preferences.shared.removeObject(forKey: channelsKey)
        }
    }

    static let quiet = "-all"
    private static let channelsKey = "wineDebug"

    /// What the diagnostics switch turns on: every channel's errors,
    /// exceptions as they are dispatched — the two that name a crash — and
    /// the process id on every line, since the client, its games and the
    /// prefix's own daemons all write to the one file.
    static let diagnostic = "err+all,+seh,+pid"

    /// Whether anything beyond the quiet default is on.
    static var isDiagnosing: Bool { channels != quiet }

    static func setDiagnosing(_ on: Bool) {
        setChannels(on ? diagnostic : nil)
    }

    /// `off`, or `on (<channels>)`.
    static var summary: String {
        isDiagnosing ? "on (\(channels))" : "off"
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
