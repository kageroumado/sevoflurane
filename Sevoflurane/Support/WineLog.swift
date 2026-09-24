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
    static let fileURL = UserHome.url
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

    /// The same line for a launch under Debug mode, which folds its own
    /// channels in: `on` whenever the mode is on, and the channels a game
    /// actually carries.
    static func summary(debugMode: Bool) -> String {
        let on = debugMode || isDiagnosing
        return "\(on ? "on" : "off") (\(effectiveChannels(debugMode: debugMode)))"
    }

    // MARK: - Composition with Debug mode

    /// The channels a launch actually carries: the bottle's own set, with
    /// Debug mode's folded in when the mode is on.
    static func effectiveChannels(debugMode: Bool) -> String {
        debugMode ? debugModeChannels : channels
    }

    /// What Debug mode writes to `debug.env`: its always-on set — every
    /// channel's errors, the pid, and the exception and library-load traces
    /// its report reads — with the bottle's own ``channels`` folded on top, so
    /// a `+d3d` set with `sevo bottle config wine-debug` keeps its trace lines
    /// through the mode. Channels named on both sides take the bottle's token,
    /// since that is the one reached for by hand.
    static var debugModeChannels: String {
        compose(levelOne, with: channels)
    }

    /// Folds one `WINEDEBUG` channel list onto another, keyed by channel name
    /// — the text after a token's `+` or `-`. Where both lists name a channel
    /// the addition's token stands, and a channel only one names is kept. Wine
    /// reads the `all` default and each named channel from separate tables
    /// (dormison `dlls/ntdll/unix/debug.c`), so a token's position in the
    /// string does not change what it means; the fold is by name, not order.
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

    /// The channel a token names: the text after its `+` or `-`, or the whole
    /// token when it carries neither.
    private static func channelName(of token: String) -> String {
        guard let sign = token.lastIndex(where: { $0 == "+" || $0 == "-" }) else {
            return token
        }
        return String(token[token.index(after: sign)...])
    }

    /// A handle appending to the log, after a header naming what is being
    /// launched. The file is rotated once past ``rotateOverBytes`` so a
    /// verbose channel left on for a week cannot fill the disk unbounded.
    /// Rotation copies and truncates rather than renaming: services.exe and
    /// winedevice.exe hold the file open from prefix boot, and a renamed
    /// inode would keep taking their output while readers watched the new
    /// file.
    static func handle(labeled label: String) -> FileHandle? {
        handle(labeled: label, at: fileURL, rotatingOver: rotateOverBytes)
    }

    /// The same handle for a log at `url`, rotated past `limit` bytes.
    ///
    /// The descriptor is opened `O_APPEND`, and every process that inherits it
    /// writes at the end of the file as it is at that moment. A shared offset
    /// would carry each writer past a truncation and leave a hole of NUL bytes
    /// the size of the rotated log in front of its next line.
    static func handle(labeled label: String, at url: URL, rotatingOver limit: Int) -> FileHandle? {
        rotateIfLarge(url, over: limit)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let stamp = ISO8601DateFormatter().string(from: .now)
        handle.write(Data("==== \(stamp) \(label) (WINEDEBUG=\(channels))\n".utf8))
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
