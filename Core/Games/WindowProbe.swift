import Foundation

/// Whether a program's windows answer, asked inside the bottle the way Task
/// Manager decides "Not responding": the bundled `window-probe.exe` sends
/// every visible window `WM_NULL` and reports which threads took it.
///
/// A game waiting for its player answers at once, however long it has used no
/// processor time and drawn nothing: a visual novel on a line of text. A
/// deadlocked one does not. Processor time and frames cannot tell the two
/// apart; this can.
nonisolated enum WindowProbe {
    enum Verdict: Equatable, Sendable {
        /// At least one of the program's windows took the message.
        case answers
        /// The program has windows on screen and none of them did.
        case deaf
    }

    /// The probe as the app ships it; nil in `sevo` and the helper, which
    /// carry no resources.
    static var bundled: URL? {
        Bundle.main.url(forResource: "window-probe", withExtension: "exe")
    }

    /// How long the probe may take: it gives each window three seconds and
    /// itself twelve, and Wine needs a moment to start it.
    static let timeout: Duration = .seconds(25)

    /// Every program with a window on screen, by lowercased executable name;
    /// nil when the probe could not be run. A program absent from the answer
    /// has no visible window.
    static func ask() async -> [String: Verdict]? {
        guard let probe = bundled else { return nil }
        let result = await ClientLifecycle.runSupervisedInBottle(
            [SteamBottle.windowsPath(for: probe)], timeout: timeout,
        )
        guard result.status == 0 else { return nil }
        return verdicts(in: result.output)
    }

    /// Reads the probe's lines, `<process id> TAB <1|0> TAB <executable>`,
    /// skipping whatever else Wine printed around them. One answering window
    /// makes a program answer: a second thread's window proves the process
    /// can still be reached.
    static func verdicts(in output: String) -> [String: Verdict] {
        var verdicts: [String: Verdict] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, UInt32(fields[0]) != nil, fields[1] == "1" || fields[1] == "0",
                  !fields[2].isEmpty else { continue }
            let exe = fields[2].lowercased()
            if fields[1] == "1" {
                verdicts[exe] = .answers
            } else if verdicts[exe] == nil {
                verdicts[exe] = .deaf
            }
        }
        return verdicts
    }
}
