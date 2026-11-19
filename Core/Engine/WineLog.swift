import Foundation

/// Where Wine's own stderr goes for every managed launch, including every
/// game the client spawns, since they inherit the descriptor.
///
/// ``levelZero`` keeps errors always on, because a game that exits in two
/// seconds leaves nothing else and `WINEDEBUG=-all` silences `err` too.
/// ``levelOne`` is the diagnostics switch.
///
/// `sevo bottle config wine-debug +seh,+loaddll` sets the channels for the
/// next client start; `sevo logs --wine` reads the trail.
nonisolated enum WineLog {
    static let fileURL = AppIdentity.logFile("wine")

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

    /// Every channel's errors, where Wine's unhandled exception record lands,
    /// and the pid on every line, since every process writes to one file.
    /// Costs a line per fault and nothing while a game runs.
    static let levelZero = "err+all,+pid"

    /// Adds dispatched exceptions (`OutputDebugString` output and every C++
    /// throw) and library loads, which tell a failed import from a later
    /// death. Tens of thousands of lines per game run.
    static let levelOne = "err+all,+pid,+seh,+loaddll"

    private static let channelsKey = "wineDebug"

    static var isDiagnosing: Bool { channels != levelZero }

    static func setDiagnosing(_ on: Bool) {
        setChannels(on ? levelOne : nil)
    }

    /// The diagnostics line for a launch, with Debug mode's channels folded in.
    static func summary(debugMode: Bool) -> String {
        let on = debugMode || isDiagnosing
        return "\(on ? "on" : "off") (\(effectiveChannels(debugMode: debugMode)))"
    }

    // MARK: - Composition with Debug mode

    static func effectiveChannels(debugMode: Bool) -> String {
        debugMode ? debugModeChannels : channels
    }

    /// What Debug mode writes to `debug.env`: ``levelOne`` with the bottle's
    /// ``channels`` folded on top, so a hand-set `+d3d` survives the mode.
    static var debugModeChannels: String {
        compose(levelOne, with: channels)
    }

    /// Folds one `WINEDEBUG` channel list onto another by channel name; where
    /// both name a channel the addition's token stands. Order is irrelevant:
    /// Wine reads `all` and each named channel from separate tables (dormison
    /// `dlls/ntdll/unix/debug.c`).
    static func compose(_ base: String, with additions: String) -> String {
        var order: [String] = []
        var token: [String: String] = [:]
        for raw in "\(base),\(additions)".split(separator: ",") {
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let channel = channelName(of: value)
            if token[channel] == nil { order.append(channel) }
            token[channel] = value
        }
        return order.compactMap { token[$0] }.joined(separator: ",")
    }

    /// The text after a token's `+` or `-`, or the whole token.
    private static func channelName(of token: String) -> String {
        guard let sign = token.lastIndex(where: { $0 == "+" || $0 == "-" }) else {
            return token
        }
        return String(token[token.index(after: sign)...])
    }

    /// A handle appending to the log after a header naming the launch,
    /// rotated past ``rotateOverBytes``. Never rotate by renaming:
    /// services.exe and winedevice.exe hold the file open from prefix boot and
    /// would keep writing to the renamed inode.
    static func handle(labeled label: String) -> FileHandle? {
        handle(labeled: label, at: fileURL, rotatingOver: rotateOverBytes)
    }

    /// The same handle for a log at `url`, rotated past `limit` bytes.
    ///
    /// Opened `O_APPEND`: a shared offset would carry inheriting writers past
    /// a truncation and leave a hole of NUL bytes before their next line.
    static func handle(labeled label: String, at url: URL, rotatingOver limit: Int) -> FileHandle? {
        rotateIfLarge(url, over: limit)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let stamp = ISO8601DateFormatter().string(from: .now)
        // The throwing write: `write(_:)` raises an Objective-C exception on a
        // full disk, which ends the process. A header that does not land is lost.
        try? handle.write(contentsOf: Data("==== \(stamp) \(label) (WINEDEBUG=\(channels))\n".utf8))
        return handle
    }

    private static let rotateOverBytes = 20_000_000

    private static func rotateIfLarge(_ url: URL, over limit: Int) {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > limit else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? manager.removeItem(at: old)
        try? manager.copyItem(at: url, to: old)
        truncate(url.path, 0)
    }
}
