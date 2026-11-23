import Foundation

/// Why a run failed and what to do about it: an ordered list of findings read
/// from the run's record and from what the app knows now. Pure, so a record
/// from the log, a test and a gallery fixture all read the same way.
nonisolated enum RunDiagnosis {
    /// Everything a run can be told about. The raw value names the cause in
    /// logs, mutes and screenshots.
    enum Cause: String, CaseIterable, Sendable {
        /// A kernel driver failed to load and nothing drew.
        case kernelDriver = "kernel-driver"
        /// The loader could not find a library the executable imports.
        case missingLibrary = "missing-library"
        /// A video decoder was fed and returned nothing.
        case videoDecodedNothing = "video-decoded-nothing"
        /// Other Macs' runs point at a setting (``SuggestedFix``).
        case suggestedFix = "suggested-fix"
        /// Unity quit with status 1 before its first window.
        case unityStartup = "unity-startup"
        /// Unreal quit with status 3.
        case unrealException = "unreal-exception"
        /// The stall watchdog ended the game.
        case stalled
        case crashed
        /// An error exit before the game was up.
        case quitWhileStarting = "quit-while-starting"
        /// The user ended a game whose window had stopped answering.
        case notAnswering = "not-answering"
        /// Workers spinning on every processor.
        case threadSpin = "thread-spin"
        /// The renderer dropped a pass it could not convert.
        case droppedShader = "dropped-shader"
        /// No rule recognizes anything in the run.
        case unexplained
    }

    /// The order findings are listed in, the first being the one a panel leads
    /// with: what explains the ending for certain, then a measured cause with a
    /// remedy, then a remedy other Macs measured, then a recognized ending,
    /// then the ending alone, then what a run that kept going showed (a
    /// one-press remedy before none), then nothing.
    static let order: [Cause] = [
        .kernelDriver, .missingLibrary,
        .videoDecodedNothing,
        .suggestedFix,
        .unityStartup, .unrealException,
        .stalled, .crashed, .quitWhileStarting, .notAnswering,
        .threadSpin, .droppedShader,
        .unexplained,
    ]

    /// The causes that say what the ending was; the ending alone is left out
    /// beside one of them.
    static let namesTheEnding: Set<Cause> = [
        .kernelDriver, .missingLibrary, .suggestedFix, .unityStartup, .unrealException,
    ]

    static let plainEndings: Set<Cause> = [.stalled, .crashed, .quitWhileStarting, .notAnswering]

    /// Causes that never open a panel by themselves: one follows a question the
    /// user has just answered, the other says nothing.
    static let silent: Set<Cause> = [.notAnswering, .unexplained]

    /// Somewhere in the app that a finding sends the user to.
    enum Guide: Equatable, Sendable {
        /// The game's page in Settings › Games.
        case gameSettings
    }

    enum Action: Equatable, Sendable {
        /// Sets these keys on the game, recorded under `source` so that
        /// Settings › Games can undo it (``FixLedger/adopt(_:source:own:record:date:)``).
        case apply(ConfigValues, label: String, source: AppliedFixes.Source)
        /// Installs a ``BottleDependencies`` package and gives the game its copy of `dll`.
        case install(dependency: String, dll: String, label: String)
        case open(Guide, label: String)
        case sendReport

        /// The button's title; the report's is the panel's own.
        var label: String? {
            switch self {
            case let .apply(_, label, _), let .install(_, _, label), let .open(_, label): label
            case .sendReport: nil
            }
        }
    }

    struct Finding: Equatable, Sendable, Identifiable {
        let cause: Cause
        /// What happened, the game named, in one sentence.
        let sentence: String
        /// The same sentence with the game as "it", for a row under another
        /// finding that already named it.
        let brief: String
        /// The one line that shows it.
        let evidence: String
        let action: Action?

        var id: Cause { cause }
    }

    /// What a diagnosis reads beside the record.
    struct Context: Sendable {
        /// The game's settings as they resolve now: its own over the bottle's.
        var current = ConfigValues.empty
        /// The fixes other Macs' runs suggest (``FixList/suggested``).
        var suggested: [SuggestedFix] = []
    }

    // MARK: - The diagnosis

    /// Every finding about `record`, in ``order``. Never empty: a run no rule
    /// recognizes yields ``Cause/unexplained``, which offers the report.
    static func findings(for record: RunRecord, in context: Context = Context()) -> [Finding] {
        var found = order.filter { $0 != .unexplained }.compactMap { finding($0, for: record, in: context) }
        if found.contains(where: { namesTheEnding.contains($0.cause) }) {
            found.removeAll { plainEndings.contains($0.cause) }
        }
        return found.isEmpty ? [unexplained(record)] : found
    }

    /// The findings that open a panel unasked.
    ///
    /// - Parameters:
    ///   - quiet: The causes the user muted for this game.
    ///   - asksAfterBadEnding: Whether a finding that only offers the report
    ///     may open one (``Preferences/asksAfterCrash``).
    static func raised(
        _ findings: [Finding], quiet: Set<Cause> = [], asksAfterBadEnding: Bool = true,
    ) -> [Finding] {
        findings.filter { finding in
            guard !silent.contains(finding.cause), !quiet.contains(finding.cause) else { return false }
            return finding.action != .sendReport || asksAfterBadEnding
        }
    }

    /// One rule: the finding `cause` yields for `record`, or nil.
    static func finding(_ cause: Cause, for record: RunRecord, in context: Context = Context()) -> Finding? {
        switch cause {
        case .kernelDriver: kernelDriver(record)
        case .missingLibrary: missingLibrary(record)
        case .videoDecodedNothing: videoDecodedNothing(record, context)
        case .suggestedFix: suggestedFix(record, context)
        case .unityStartup, .unrealException, .droppedShader: knownFailure(cause, record)
        case .stalled: stalled(record)
        case .crashed: crashed(record)
        case .quitWhileStarting: quitWhileStarting(record)
        case .notAnswering: notAnswering(record)
        case .threadSpin: threadSpin(record, context)
        case .unexplained: unexplained(record)
        }
    }

    // MARK: - Endings

    /// A crash, the stall watchdog's kill, an error exit while the game was
    /// starting, or a hang the user ended.
    static func endedBadly(_ record: RunRecord) -> Bool {
        switch record.exit?.kind {
        case .crash, .watchdog, .endedNotResponding: true
        case .exitError: isQuitWhileStarting(record)
        default: false
        }
    }

    /// An error exit before the game was up: under ``startingSeconds``, or under
    /// ``windowlessSeconds`` (or unmeasured) without ever showing a window. A
    /// game's own crash handler often ends this way; an error exit after play is
    /// how plenty of games quit.
    static func isQuitWhileStarting(_ record: RunRecord) -> Bool {
        guard record.exit?.kind == .exitError else { return false }
        if let duration = record.durationSeconds, duration < startingSeconds { return true }
        return record.windowAfterSeconds == nil && (record.durationSeconds ?? 0) < windowlessSeconds
    }

    /// How long a game is still starting, for ``isQuitWhileStarting(_:)``.
    static let startingSeconds: Double = 30
    static let windowlessSeconds: Double = 120

    private static func crashed(_ record: RunRecord) -> Finding? {
        guard record.exit?.kind == .crash else { return nil }
        var what: String
        if let crash = record.crash {
            let status = statusName(crash.code)
            what = crash.module.map { String(localized: "\(status) (\(crash.code)) in \($0)") }
                ?? String(localized: "\(status) (\(crash.code))")
        } else if let code = record.exit?.code {
            what = String(localized: "Exit status \(code)")
        } else {
            what = String(localized: "An unhandled exception")
        }
        if let lasted = lasted(record) { what = String(localized: "\(what), \(lasted) in.") } else { what += "." }
        return make(.crashed, record, evidence: what, action: .sendReport) {
            String(localized: "\($0.leading) stopped unexpectedly.")
        }
    }

    private static func quitWhileStarting(_ record: RunRecord) -> Finding? {
        guard isQuitWhileStarting(record) else { return nil }
        let status = record.exit?.code.map(String.init) ?? "?"
        let evidence = switch (lasted(record), record.windowAfterSeconds) {
        case let (lasted?, nil): String(localized: "Exit status \(status) after \(lasted), before any window.")
        case let (lasted?, _?): String(localized: "Exit status \(status) after \(lasted).")
        case (nil, _): String(localized: "Exit status \(status).")
        }
        return make(.quitWhileStarting, record, evidence: evidence, action: .sendReport) {
            String(localized: "\($0.leading) quit with an error while starting.")
        }
    }

    private static func stalled(_ record: RunRecord) -> Finding? {
        guard record.exit?.kind == .watchdog else { return nil }
        let evidence = record.stalls?.last.map {
            String(localized: "Its last stall lasted \(Int($0.duration.rounded())) s and nothing got it moving.")
        } ?? String(localized: "Nothing got it moving again.")
        return make(.stalled, record, evidence: evidence, action: .sendReport) {
            String(localized: "\($0.leading) froze, and Sevoflurane ended it.")
        }
    }

    private static func notAnswering(_ record: RunRecord) -> Finding? {
        guard record.exit?.kind == .endedNotResponding else { return nil }
        return make(
            .notAnswering, record,
            evidence: String(localized: "Its window took no clicks, keys or its close button."),
            action: .sendReport,
        ) { String(localized: "\($0.leading) stopped answering, and you ended it.") }
    }

    private static func unexplained(_ record: RunRecord) -> Finding {
        make(.unexplained, record, evidence: record.displayOutcome, action: .sendReport) {
            String(localized: "Nothing in this run of \($0.within) points at a problem.")
        }
    }

    // MARK: - What the log named

    private static func kernelDriver(_ record: RunRecord) -> Finding? {
        guard let driver = record.driver else { return nil }
        return make(
            .kernelDriver, record,
            evidence: String(localized: "\(driver) failed to load, and the game drew nothing."),
            action: nil,
        ) { String(localized: "\($0.leading) needs a Windows kernel driver, which cannot run on a Mac.") }
    }

    private static func missingLibrary(_ record: RunRecord) -> Finding? {
        guard let dll = record.missingDLL else { return nil }
        let say: (Subject) -> String = { String(localized: "\($0.leading) could not start without \(dll).") }
        guard let repair = KnownFixes.dllRepair(for: dll) else {
            return make(
                .missingLibrary, record,
                evidence: String(localized: "No package Sevoflurane installs carries \(dll)."),
                action: .sendReport, say,
            )
        }
        // The evidence names the package, so the button carries the verb and the download's size.
        let size = BottleDependencies.catalog.first { $0.id == repair.dependency }?.download
        return make(
            .missingLibrary, record,
            evidence: String(localized: "\(repair.packageName) includes \(dll)."),
            action: .install(
                dependency: repair.dependency, dll: repair.dll,
                label: size.map { String(localized: "Install (\($0))") } ?? String(localized: "Install"),
            ), say,
        )
    }

    private static func videoDecodedNothing(_ record: RunRecord, _ context: Context) -> Finding? {
        let current = context.current.videoDecoding ?? .hardware
        guard let suggestion = VideoDecodingDiagnosis.suggestion(for: record, current: current) else { return nil }
        let buffers = suggestion.video.buffers
        let stream = streamName(suggestion.video.stream)
        let evidence: String
        let label: String
        let reason: String
        switch suggestion.offered {
        case .software:
            evidence = String(localized: "The Mac\u{2019}s hardware decoder returned none of \(buffers) \(stream) frames.")
            label = String(localized: "Use Software Decoding")
            reason = "The hardware decoder returned none of this game\u{2019}s video frames in a run on this Mac."
        case .hardware:
            evidence = String(localized: "The software decoders returned none of \(buffers) \(stream) frames.")
            label = String(localized: "Use Hardware Decoding")
            reason = "The software decoders returned none of this game\u{2019}s video frames in a run on this Mac."
        }
        let action = Action.apply(
            ConfigValues(videoDecoding: suggestion.offered), label: label,
            source: AppliedFixes.Source(title: String(localized: "Video decoding"), reason: reason),
        )
        return make(.videoDecodedNothing, record, evidence: evidence, action: action) {
            String(localized: "\($0.leading) shows a blank picture where a video should play.")
        }
    }

    // MARK: - What other Macs measured

    private static func suggestedFix(_ record: RunRecord, _ context: Context) -> Finding? {
        guard endedBadly(record) else { return nil }
        let exes = record.exe.map { [$0] } ?? []
        guard let suggestion = context.suggested.first(where: { suggestion in
            suggestion.fix.matches(appID: record.appid, exes: exes)
                && !isInForce(suggestion.fix.values, record: record, current: context.current)
                && suggestion.evidence.without.values
                .map { isInForce($0, record: record, current: context.current) } != false
        }) else { return nil }
        let values = suggestion.fix.values
        let change = settingChange(values)
        let action = Action.apply(
            values,
            label: change.map { String(localized: "Set \($0.title) to \($0.value)") }
                ?? String(localized: "Apply Suggested Fix"),
            source: AppliedFixes.Source(title: suggestion.fix.title, reason: suggestion.fix.reason),
        )
        let before = suggestion.evidence.without.values.flatMap(settingChange)?.value
        return make(
            .suggestedFix, record, evidence: evidenceLine(suggestion.evidence, with: values), action: action,
        ) { subject in
            before.map { String(localized: "\(subject.leading) also fails on \($0) on other Macs.") }
                ?? String(localized: "\(subject.leading) also fails on other Macs with these settings.")
        }
    }

    /// Whether every key of `values` holds for the game. The renderer is read
    /// from the run where the game inherits it.
    static func isInForce(_ values: ConfigValues, record: RunRecord, current: ConfigValues) -> Bool {
        var now = current.fields
        if now["renderer"] == nil, record.rendererConfirmed != false { now["renderer"] = record.renderer }
        return values.fields.allSatisfy { FixLedger.same(now[$0.key], $0.value) }
    }

    /// `2 Macs: 11 of 15 runs failed on D3DMetal, 0 of 6 on DXMT.`
    static func evidenceLine(_ evidence: FixEvidence, with values: ConfigValues) -> String {
        let macs = evidence.macs == 1 ? String(localized: "1 Mac") : String(localized: "\(evidence.macs) Macs")
        let without = evidence.without
        let with = evidence.with
        guard let before = without.values.flatMap(settingChange)?.value, let after = settingChange(values)?.value else {
            return String(localized: "\(macs): \(without.failed) of \(without.runs) runs failed without the change, \(with.failed) of \(with.runs) with it.")
        }
        return String(localized: "\(macs): \(without.failed) of \(without.runs) runs failed on \(before), \(with.failed) of \(with.runs) on \(after).")
    }

    /// The one catalog setting `values` sets, in Settings' words; nil for more
    /// than one key or a key with no row.
    private static func settingChange(_ values: ConfigValues) -> (title: String, value: String)? {
        let keys = values.fields.keys
        guard keys.count == 1, let key = keys.first, let id = SettingID(rawValue: key) else { return nil }
        let setting = SettingCatalog.setting(id)
        guard let value = setting.read(values) else { return nil }
        return (setting.title, setting.label(of: value))
    }

    // MARK: - What the run showed

    private static func threadSpin(_ record: RunRecord, _ context: Context) -> Finding? {
        guard let suggestion = ThreadSpinDiagnosis.suggestion(for: record, currentCap: context.current.processors)
        else { return nil }
        let cap = suggestion.cap
        let action = Action.apply(
            ConfigValues(processors: cap), label: String(localized: "Limit to \(cap) Processors"),
            source: AppliedFixes.Source(
                title: String(localized: "Processor limit"),
                reason: "A run on this Mac kept a worker spinning on every processor.",
            ),
        )
        return make(
            .threadSpin, record,
            evidence: String(localized: "Its workers never rest on \(suggestion.processors) processors. Told of \(cap), they sleep."),
            action: action,
        ) {
            String(localized: "\($0.leading) kept \(suggestion.busy) threads busy the whole time, which slows its picture.")
        }
    }

    /// The ``KnownFailures`` entry behind each cause that is one.
    static let knownFailures: [Cause: String] = [
        .unityStartup: "unity-exit-1-no-window",
        .unrealException: "unreal-exit-3",
        .droppedShader: "dxmt-dropped-compute",
    ]

    private static func knownFailure(_ cause: Cause, _ record: RunRecord) -> Finding? {
        guard let id = knownFailures[cause],
              KnownFailures.all.first(where: { $0.id == id })?.matches(record) == true else { return nil }
        switch cause {
        case .unityStartup:
            return make(
                cause, record,
                evidence: String(localized: "Unity quit with status 1. Its Player.log, in the report, says why."),
                action: .sendReport,
            ) { String(localized: "\($0.leading) failed while starting and never drew a window.") }
        case .unrealException:
            return make(
                cause, record,
                evidence: String(localized: "Unreal quit with status 3 and wrote a callstack, which the report carries."),
                action: .sendReport,
            ) { String(localized: "\($0.leading) crashed in the game\u{2019}s own code.") }
        default:
            return make(
                cause, record,
                evidence: String(localized: "DXMT could not convert a shader to Metal, so a pass never ran."),
                action: .open(.gameSettings, label: String(localized: "Choose Another Renderer")),
            ) { String(localized: "\($0.leading) is missing part of its picture.") }
        }
    }

    // MARK: - Words

    /// How a sentence names the game: at its head and inside it.
    private struct Subject {
        let leading: String
        let within: String
    }

    /// A finding whose sentence is said twice: with the game's name, and with
    /// "it" for a row under a finding that already named the game.
    private static func make(
        _ cause: Cause, _ record: RunRecord, evidence: String, action: Action?, _ say: (Subject) -> String,
    ) -> Finding {
        let named = record.name.map { Subject(leading: $0, within: $0) }
            ?? Subject(leading: String(localized: "The game"), within: String(localized: "the game"))
        let it = Subject(leading: String(localized: "It"), within: String(localized: "it"))
        return Finding(cause: cause, sentence: say(named), brief: say(it), evidence: evidence, action: action)
    }

    /// `61 s` or `12 min`.
    private static func lasted(_ record: RunRecord) -> String? {
        guard let seconds = record.durationSeconds else { return nil }
        return seconds < 90
            ? String(localized: "\(Int(seconds.rounded())) s")
            : String(localized: "\(Int((seconds / 60).rounded())) min")
    }

    /// What an NT status is called, for the ones that end games.
    static func statusName(_ code: String) -> String {
        switch code.lowercased() {
        case "0xc0000005": String(localized: "Access violation")
        case "0xc00000fd": String(localized: "Stack overflow")
        case "0xc000001d": String(localized: "Illegal instruction")
        case "0xc0000094": String(localized: "Division by zero")
        case "0xc0000409": String(localized: "Stack buffer overrun")
        case "0xc0000135": String(localized: "Missing library")
        case "0xe06d7363": String(localized: "C++ exception")
        default: String(localized: "Exception")
        }
    }

    /// GStreamer's `video/x-h264` as people write it, `H.264`.
    static func streamName(_ type: String) -> String {
        let bare = type.split(separator: "/").last.map(String.init) ?? type
        let codec = bare.hasPrefix("x-") ? String(bare.dropFirst(2)) : bare
        switch codec.lowercased() {
        case "h264": return "H.264"
        case "h265": return "H.265"
        default: return codec.uppercased()
        }
    }
}
