import Foundation

/// What the Wine log gained during a run, read for the two things it can say
/// on its own: an unhandled exception, and the renderer complaining.
nonisolated enum WineExceptionTrail {
    /// The last unhandled exception in the text — the one that ended the
    /// process, since Wine terminates it on the spot.
    static func lastException(in text: String) -> RunRecord.Crash? {
        var found: RunRecord.Crash?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: unhandled) else { continue }
            found = RunRecord.Crash(
                code: "0x\(match.output.1)",
                flags: "0x\(match.output.2)",
                address: String(match.output.3),
                module: nil,
            )
        }
        return found
    }

    /// The renderer's own complaints, deduplicated with a count. DXMT writes
    /// these whatever `WINEDEBUG` says, and each one is a Direct3D call that
    /// did not do what the game asked.
    static func notes(in text: String) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let marker = markers.first(where: { line.contains($0) }) else { continue }
            let note = String(
                line[(line.range(of: marker)?.lowerBound ?? line.startIndex)...],
            ).trimmingCharacters(in: .whitespaces)
            if counts[note] == nil { order.append(note) }
            counts[note, default: 0] += 1
        }
        return order.prefix(maximumNotes).map { note in
            let count = counts[note] ?? 1
            return count > 1 ? "\(note) ×\(count)" : note
        }
    }

    private static let markers = ["Not supported feature:", "Shader not found?"]
    private static let maximumNotes = 8

    /// `dlls/ntdll/unix/thread.c`'s last word before it terminates the
    /// process; `err:seh` is in the always-on channels.
    private nonisolated(unsafe) static let unhandled =
        /Unhandled exception code ([0-9a-fA-F]+) flags ([0-9a-fA-F]+) addr (0x[0-9a-fA-F]+)/
}
