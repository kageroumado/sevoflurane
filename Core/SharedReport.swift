import Foundation

/// What a person says about one run, as the community database receives it
/// (`infrastructure/sevostats/reports_ingest.go`): a verdict on ProtonDB's
/// ladder in four steps, a note, and the configuration of the run it is
/// about, copied from the ``RunRecord`` rather than typed. Like ``SharedRun``
/// it carries no title, path, renderer note or anything naming the player;
/// the note is the one field a person writes, and it is public.
///
/// The keys are the wire format, version ``version``; changing one is a
/// version bump on both ends.
nonisolated struct SharedReport: Codable, Equatable, Sendable {
    static let version = 1
    /// The note's cap in Unicode scalars, the server's `maxNoteRunes`.
    static let noteLimit = 600
    /// The server's cap on one item as sent. A report whose note is
    /// ``noteLimit`` four-byte characters long, on the longest configuration
    /// values the server accepts, encodes well under it, so nothing is trimmed
    /// at send time.
    static let itemLimit = 4096

    enum Verdict: String, Codable, CaseIterable, Sendable {
        /// Nothing to do.
        case plays
        /// The note says which: a renderer pin, a toolkit, a launch option.
        case playsWithFixes = "plays-with-fixes"
        /// Menu or first frames, then trouble.
        case launches
        /// No window, or dies at start.
        case fails

        var displayName: String {
            switch self {
            case .plays: String(localized: "Plays")
            case .playsWithFixes: String(localized: "Plays with fixes")
            case .launches: String(localized: "Launches")
            case .fails: String(localized: "Fails")
            }
        }
    }

    var v: Int
    /// The Steam app id, absent for a program Steam does not know.
    var appid: Int?
    /// For a program without an appid, the executable's file name.
    var exe: String?
    /// For a program without an appid, its own name for itself.
    var product: String?
    var engine: String
    var renderer: String
    var runner: String
    var settings: SharedRun.Settings
    var macos: String
    var chip: String?
    var verdict: Verdict
    var note: String
    /// The `t` of the run the report is about, stored by the server and never shown.
    var runRef: String

    enum CodingKeys: String, CodingKey {
        case v
        case appid
        case exe
        case product
        case engine
        case renderer
        case runner
        case settings
        case macos
        case chip
        case verdict
        case note
        case runRef = "run_ref"
    }

    /// A report on `record`, with `note` tidied and cut to ``noteLimit``.
    init(record: RunRecord, verdict: Verdict, note: String) {
        let adopted = AdoptedPrograms.isAdopted(record.appid)
        v = Self.version
        appid = adopted ? nil : record.appid
        exe = adopted ? record.exe.map { ($0 as NSString).lastPathComponent } : nil
        product = adopted ? record.product : nil
        engine = record.engine
        renderer = record.renderer
        runner = record.runner
        settings = SharedRun.Settings(
            windows: record.windows, tuning: record.tuning, upscaler: record.upscaler,
            msync: record.msync, d3dmetal: record.d3dmetal,
        )
        macos = record.macos
        chip = record.chip
        self.verdict = verdict
        self.note = Self.clipped(Self.tidy(note))
        runRef = record.t
    }

    /// The JSON exactly as it is sent.
    var json: String {
        let encoder = JSONEncoder.stats
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: - The configuration as the page shows it

    /// The run's configuration as small chips, in the order the game's page
    /// shows them: engine, renderer with its D3DMetal version, the runner when
    /// it is NW.js, the upscaler when one was on, msync and experimental
    /// tuning when on, then macOS and the chip.
    static func chips(for record: RunRecord) -> [String] {
        var chips = [record.engine]
        var renderer = record.renderer
        if record.renderer == "d3dmetal", let toolkit = record.d3dmetal, !toolkit.isEmpty {
            renderer += " \(toolkit)"
        }
        chips.append(renderer)
        if record.runner == "nwjs" { chips.append("NW.js runner") }
        if let upscaler = record.upscaler, !upscaler.isEmpty, upscaler != UpscalerChoice.off.rawValue {
            chips.append(upscaler)
        }
        if record.msync { chips.append("msync") }
        if record.tuning == PerformanceTuning.experimental.rawValue { chips.append("experimental tuning") }
        chips.append("macOS \(record.macos)")
        if let chip = record.chip { chips.append(chip) }
        return chips
    }

    // MARK: - The note

    /// Why the server would refuse a note, checked here so the person hears
    /// it before the report leaves rather than in a log line after.
    enum NoteProblem: Equatable, Sendable {
        case tooLong
        case namesPath
        case namesEmail
        case notPlainText
        /// `plays-with-fixes` without a note: the note is where the fixes are named.
        case fixesUnnamed

        var sentence: String {
            switch self {
            case .tooLong: String(localized: "The note is over \(SharedReport.noteLimit) characters.")
            case .namesPath: String(localized: "The note names a file path. Reports are public, so paths stay out.")
            case .namesEmail: String(localized: "The note names an e-mail address. Reports are public, so addresses stay out.")
            case .notPlainText: String(localized: "The note has characters that are not plain text.")
            case .fixesUnnamed: String(localized: "\u{201C}Plays with fixes\u{201D} needs a note saying which fixes.")
            }
        }
    }

    /// The server's own checks on a note, in its order: URLs stripped, the
    /// text tidied, then length, plain text, an e-mail address and a file
    /// path, the last two on the NFKC form so fullwidth punctuation reads as
    /// ASCII (`scrubNote` and `checkNote` in `reports.go`).
    static func noteProblem(_ note: String, verdict: Verdict) -> NoteProblem? {
        let tidied = tidy(urlPattern.stringByReplacingMatches(
            in: note, range: NSRange(note.startIndex..., in: note), withTemplate: "",
        ))
        if tidied.unicodeScalars.count > noteLimit { return .tooLong }
        if tidied.unicodeScalars.contains(where: { $0 != "\n" && $0.properties.generalCategory == .control }) {
            return .notPlainText
        }
        let folded = tidied.precomposedStringWithCompatibilityMapping
        let whole = NSRange(folded.startIndex..., in: folded)
        if emailPattern.firstMatch(in: folded, range: whole) != nil { return .namesEmail }
        if pathPattern.firstMatch(in: folded, range: whole) != nil { return .namesPath }
        if tidied.isEmpty, verdict == .playsWithFixes { return .fixesUnnamed }
        return nil
    }

    /// Trims a note and folds runs of spaces and of blank lines, as the
    /// server does before it checks the length.
    static func tidy(_ note: String) -> String {
        var lines: [String] = []
        var blank = false
        for line in note.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let folded = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if folded.isEmpty {
                blank = true
                continue
            }
            if blank, !lines.isEmpty { lines.append("") }
            blank = false
            lines.append(folded)
        }
        return lines.joined(separator: "\n")
    }

    /// The first ``noteLimit`` scalars of a note.
    static func clipped(_ note: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: note.unicodeScalars.prefix(noteLimit))
        return String(scalars)
    }

    private static let urlPattern = pattern(#"(?i)\b(?:https?://|www\.)[^\s<>"']+"#)

    private static let emailPattern = pattern(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    /// A file path: a `file:` URL, a home folder, a root folder of macOS or
    /// Unix after either separator, a home folder's child at the start of a
    /// word, two segments under either separator, or a Windows drive or UNC
    /// prefix.
    private static let pathPattern = pattern(
        #"(?i)(?:file:/+|~[/\\]|[/\\](?:Users|Applications|Volumes|Library|System|home|tmp|var|private|opt|etc)\b"#
            + #"|(?:^|[\s"'(\[<])(?:Users|home)[/\\][^\s/\\]+|/[^\s/]+/[^\s/]+|\\[^\s\\]+\\[^\s\\]+|[A-Za-z]:\\|\\\\)"#,
    )

    /// The server's patterns, copied from `reports_ingest.go`; each is a
    /// literal the tests above exercise, so one that fails to compile is a
    /// typo in this file.
    private static func pattern(_ source: String) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(pattern: source) else {
            preconditionFailure("the pattern \(source) does not compile")
        }
        return expression
    }
}
