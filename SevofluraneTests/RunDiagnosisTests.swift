import Foundation
import Testing
@testable import Sevoflurane

/// Why a run failed: each rule on its own, the order the findings come in,
/// which of them open a panel, and that every cause has words and a fixture.
@MainActor
struct RunDiagnosisTests {
    private static func record(
        appid: Int = 508_440,
        exit: RunRecord.Exit? = RunRecord.Exit(kind: .user, code: 0),
        lasting seconds: Double? = 600,
        _ change: (inout RunRecord) -> Void = { _ in },
    ) -> RunRecord {
        var record = RunRecord(
            t: "2026-11-23T10:00:00Z",
            appid: appid,
            name: "Totally Accurate Battle Simulator",
            engine: "dormison-r14",
            renderer: "d3dmetal",
            rendererConfirmed: true,
            runner: "wine",
            windows: "fixed",
            msync: true,
            macos: "27.0",
            durationSeconds: seconds,
            exit: exit,
            host: RunRecord.Host(thermal: "nominal", load: 1.2),
        )
        change(&record)
        return record
    }

    private static let crash = RunRecord.Exit(kind: .crash, code: 3)

    private static func suggestion(
        appID: Int = 508_440, values: ConfigValues = ConfigValues(renderer: .dxmt),
        without: ConfigValues? = ConfigValues(renderer: .d3dmetal),
    ) -> SuggestedFix {
        SuggestedFix(
            fix: KnownFix(appID: appID, exePattern: nil, title: "TABS", values: values, reason: "Measured."),
            evidence: FixEvidence(
                macs: 2, without: .init(values: without, runs: 15, failed: 11), with: .init(values: nil, runs: 6, failed: 0),
            ),
        )
    }

    private static func causes(_ record: RunRecord, in context: RunDiagnosis.Context = .init()) -> [RunDiagnosis.Cause] {
        RunDiagnosis.findings(for: record, in: context).map(\.cause)
    }

    // MARK: - The rules, one by one

    @Test
    func `nothing known still yields a finding that offers the report`() {
        let findings = RunDiagnosis.findings(for: Self.record())
        #expect(findings.map(\.cause) == [.unexplained])
        #expect(findings.first?.action == .sendReport)
        #expect(findings.first?.sentence == "Nothing in this run of Totally Accurate Battle Simulator points at a problem.")
        #expect(findings.first?.evidence.contains("exited normally") == true)
        for kind in [RunRecord.Exit.Kind.crashAtExit, .stopped, .stoppedByTool, .steamTerminate, .appQuit, .unknown] {
            #expect(Self.causes(Self.record(exit: RunRecord.Exit(kind: kind, code: 0))) == [.unexplained])
        }
        #expect(Self.causes(Self.record(exit: nil)) == [.unexplained])
    }

    @Test
    func `a crash names its status, its module and how far in it came`() throws {
        let record = Self.record(exit: Self.crash, lasting: 61) {
            $0.crash = RunRecord.Crash(code: "0xc0000005", flags: nil, address: "0x1400", module: "UnityPlayer.dll")
        }
        let finding = try #require(RunDiagnosis.finding(.crashed, for: record))
        #expect(finding.sentence == "Totally Accurate Battle Simulator stopped unexpectedly.")
        #expect(finding.brief == "It stopped unexpectedly.")
        #expect(finding.evidence == "Access violation (0xc0000005) in UnityPlayer.dll, 61 s in.")
        #expect(finding.action == .sendReport)
        let bare = try #require(RunDiagnosis.finding(.crashed, for: Self.record(exit: Self.crash, lasting: 754)))
        #expect(bare.evidence == "Exit status 3, 13 min in.")
        #expect(RunDiagnosis.finding(.crashed, for: Self.record()) == nil)
    }

    @Test
    func `an error exit is a finding only while the game was starting`() throws {
        let early = Self.record(exit: RunRecord.Exit(kind: .exitError, code: 1), lasting: 8)
        let finding = try #require(RunDiagnosis.finding(.quitWhileStarting, for: early))
        #expect(finding.sentence == "Totally Accurate Battle Simulator quit with an error while starting.")
        #expect(finding.evidence == "Exit status 1 after 8 s, before any window.")
        let windowed = Self.record(exit: RunRecord.Exit(kind: .exitError, code: 1), lasting: 8) {
            $0.windowAfterSeconds = 3
        }
        #expect(RunDiagnosis.finding(.quitWhileStarting, for: windowed)?.evidence == "Exit status 1 after 8 s.")
        let played = Self.record(exit: RunRecord.Exit(kind: .exitError, code: 1), lasting: 600) {
            $0.windowAfterSeconds = 4
        }
        #expect(RunDiagnosis.finding(.quitWhileStarting, for: played) == nil)
        #expect(Self.causes(played) == [.unexplained])
        // No window for under two minutes is still starting.
        #expect(RunDiagnosis.isQuitWhileStarting(Self.record(exit: RunRecord.Exit(kind: .exitError, code: 1), lasting: 90)))
    }

    @Test
    func `the watchdog's kill and a hang the user ended are their own findings`() throws {
        let killed = Self.record(exit: RunRecord.Exit(kind: .watchdog, code: nil)) {
            $0.stalls = [RunRecord.Stall(at: 555, duration: 45.2, unwedged: nil)]
        }
        let stalled = try #require(RunDiagnosis.finding(.stalled, for: killed))
        #expect(stalled.sentence == "Totally Accurate Battle Simulator froze, and Sevoflurane ended it.")
        #expect(stalled.evidence == "Its last stall lasted 45 s and nothing got it moving.")
        #expect(Self.causes(killed) == [.stalled])

        let ended = Self.record(exit: RunRecord.Exit(kind: .endedNotResponding, code: nil))
        #expect(RunDiagnosis.finding(.notAnswering, for: ended)?.action == .sendReport)
        #expect(Self.causes(ended) == [.notAnswering])
    }

    @Test
    func `a kernel driver that failed while nothing drew explains the run and offers nothing`() throws {
        let record = Self.record(exit: RunRecord.Exit(kind: .exitError, code: 1), lasting: 12) {
            $0.driver = "EasyAntiCheat.sys"
        }
        let finding = try #require(RunDiagnosis.finding(.kernelDriver, for: record))
        #expect(finding.sentence == "Totally Accurate Battle Simulator needs a Windows kernel driver, which cannot run on a Mac.")
        #expect(finding.evidence == "EasyAntiCheat.sys failed to load, and the game drew nothing.")
        #expect(finding.action == nil)
        // The ending alone adds nothing beside it.
        #expect(Self.causes(record) == [.kernelDriver])
        #expect(RunDiagnosis.finding(.kernelDriver, for: Self.record()) == nil)
    }

    @Test
    func `a missing library offers the package that carries it, or the report`() throws {
        let record = Self.record(exit: Self.crash, lasting: 2) { $0.missingDLL = "MSVCP140.dll" }
        let finding = try #require(RunDiagnosis.finding(.missingLibrary, for: record))
        #expect(finding.sentence == "Totally Accurate Battle Simulator could not start without MSVCP140.dll.")
        #expect(finding.evidence.hasSuffix(" includes MSVCP140.dll."))
        guard case let .install(dependency, dll, label) = finding.action else {
            Issue.record("no install action: \(String(describing: finding.action))")
            return
        }
        #expect(dependency == "vcredist")
        #expect(dll == "msvcp140")
        #expect(label.hasPrefix("Install ("))
        #expect(Self.causes(record) == [.missingLibrary])

        let unknown = Self.record(exit: Self.crash, lasting: 2) { $0.missingDLL = "steam_api64.dll" }
        let reported = try #require(RunDiagnosis.finding(.missingLibrary, for: unknown))
        #expect(reported.action == .sendReport)
        #expect(reported.evidence == "No package Sevoflurane installs carries steam_api64.dll.")
    }

    @Test
    func `a video that decoded nothing offers the other decoder`() throws {
        let record = Self.record {
            $0.video = RunRecord.Video(buffers: 30, stream: "video/x-h264", decoding: "hardware")
        }
        let finding = try #require(RunDiagnosis.finding(.videoDecodedNothing, for: record))
        #expect(finding.sentence == "Totally Accurate Battle Simulator shows a blank picture where a video should play.")
        #expect(finding.evidence == "The Mac\u{2019}s hardware decoder returned none of 30 H.264 frames.")
        guard case let .apply(values, label, _) = finding.action else {
            Issue.record("no setting to apply")
            return
        }
        #expect(values == ConfigValues(videoDecoding: .software))
        #expect(label == "Use Software Decoding")
        // The game was switched since the run.
        let switched = RunDiagnosis.Context(current: ConfigValues(videoDecoding: .software))
        #expect(RunDiagnosis.finding(.videoDecodedNothing, for: record, in: switched) == nil)
        #expect(RunDiagnosis.streamName("video/x-wmv") == "WMV")
    }

    @Test
    func `a suggested fix is offered with its evidence after a bad ending on the failing side`() throws {
        let record = Self.record(exit: Self.crash)
        let context = RunDiagnosis.Context(suggested: [Self.suggestion()])
        let finding = try #require(RunDiagnosis.finding(.suggestedFix, for: record, in: context))
        #expect(finding.sentence == "Totally Accurate Battle Simulator also fails on D3DMetal on other Macs.")
        #expect(finding.evidence == "2 Macs: 11 of 15 runs failed on D3DMetal, 0 of 6 on DXMT.")
        guard case let .apply(values, label, source) = finding.action else {
            Issue.record("no setting to apply")
            return
        }
        #expect(values == ConfigValues(renderer: .dxmt))
        #expect(label == "Set Renderer to DXMT")
        #expect(source == AppliedFixes.Source(title: "TABS", reason: "Measured."))
        // The crash is what the suggestion is about.
        #expect(Self.causes(record, in: context) == [.suggestedFix])
    }

    @Test
    func `a suggested fix stays silent for a run that ended well, another game, or values in force`() {
        let context = RunDiagnosis.Context(suggested: [Self.suggestion()])
        #expect(RunDiagnosis.finding(.suggestedFix, for: Self.record(), in: context) == nil)
        #expect(RunDiagnosis.finding(.suggestedFix, for: Self.record(appid: 1, exit: Self.crash), in: context) == nil)
        // The game already holds the value.
        let held = RunDiagnosis.Context(current: ConfigValues(renderer: .dxmt), suggested: [Self.suggestion()])
        #expect(RunDiagnosis.finding(.suggestedFix, for: Self.record(exit: Self.crash), in: held) == nil)
        // The run already drew through it without the game asking.
        let onDXMT = Self.record(exit: Self.crash) { $0.renderer = "dxmt" }
        #expect(RunDiagnosis.finding(.suggestedFix, for: onDXMT, in: context) == nil)
        // The run was on neither side the evidence compares.
        let elsewhere = Self.record(exit: Self.crash) { $0.renderer = "wined3d" }
        #expect(RunDiagnosis.finding(.suggestedFix, for: elsewhere, in: context) == nil)
    }

    @Test
    func `a suggestion of several keys, or with no side named, says so in plain words`() throws {
        let several = Self.suggestion(values: ConfigValues(renderer: .dxmt, processors: 6), without: nil)
        let finding = try #require(RunDiagnosis.finding(
            .suggestedFix, for: Self.record(exit: Self.crash), in: RunDiagnosis.Context(suggested: [several]),
        ))
        #expect(finding.sentence == "Totally Accurate Battle Simulator also fails on other Macs with these settings.")
        #expect(finding.evidence == "2 Macs: 11 of 15 runs failed without the change, 0 of 6 with it.")
        #expect(finding.action?.label == "Apply Suggested Fix")
        var one = Self.suggestion().evidence
        one.macs = 1
        #expect(RunDiagnosis.evidenceLine(one, with: ConfigValues(renderer: .dxmt)).hasPrefix("1 Mac: "))
    }

    @Test
    func `the known failures that explain a run are findings, and the cosmetic one is not`() throws {
        let unity = Self.record(exit: RunRecord.Exit(kind: .exitError, code: 1), lasting: 8) { $0.runtime = "unity" }
        #expect(Self.causes(unity) == [.unityStartup])
        #expect(RunDiagnosis.finding(.unityStartup, for: unity)?.evidence.contains("Player.log") == true)
        let unreal = Self.record(exit: Self.crash) { $0.runtime = "unreal" }
        #expect(Self.causes(unreal) == [.unrealException])
        let dropped = Self.record { $0.notes = ["Shader not found? ×12"] }
        let finding = try #require(RunDiagnosis.finding(.droppedShader, for: dropped))
        #expect(finding.action == .open(.gameSettings, label: "Choose Another Renderer"))
        let cosmetic = Self.record { $0.notes = ["Not supported feature: 7"] }
        #expect(Self.causes(cosmetic) == [.unexplained])
        // Every known failure is a cause or the one that says of itself it is cosmetic.
        let mapped = Set(RunDiagnosis.knownFailures.values)
        #expect(Set(KnownFailures.all.map(\.id)).subtracting(mapped) == ["dxmt-unsupported-feature"])
        #expect(mapped.isSubset(of: KnownFailures.all.map(\.id)))
    }

    @Test
    func `spinning workers offer the processor limit`() throws {
        let record = Self.record { $0.threads = RunRecord.Threads(busy: 15, processors: 16, samples: 30) }
        let finding = try #require(RunDiagnosis.finding(.threadSpin, for: record))
        #expect(finding.sentence == "Totally Accurate Battle Simulator kept 15 threads busy the whole time, which slows its picture.")
        #expect(finding.evidence == "Its workers never rest on 16 processors. Told of 8, they sleep.")
        guard case let .apply(values, label, _) = finding.action else {
            Issue.record("no setting to apply")
            return
        }
        #expect(values == ConfigValues(processors: 8))
        #expect(label == "Limit to 8 Processors")
        let capped = RunDiagnosis.Context(current: ConfigValues(processors: 8))
        #expect(RunDiagnosis.finding(.threadSpin, for: record, in: capped) == nil)
    }

    // MARK: - The order and what opens a panel

    @Test
    func `the order is stated once and names every cause`() {
        #expect(Set(RunDiagnosis.order) == Set(RunDiagnosis.Cause.allCases))
        #expect(RunDiagnosis.order.count == RunDiagnosis.Cause.allCases.count)
        #expect(RunDiagnosis.order.last == .unexplained)
    }

    @Test
    func `findings come in the stated order, the ending after what explains more`() {
        let record = Self.record(exit: Self.crash) {
            $0.video = RunRecord.Video(buffers: 30, stream: "video/x-h264", decoding: "hardware")
            $0.threads = RunRecord.Threads(busy: 15, processors: 16, samples: 30)
            $0.notes = ["Shader not found? ×12"]
        }
        #expect(Self.causes(record) == [.videoDecodedNothing, .crashed, .threadSpin, .droppedShader])
        let context = RunDiagnosis.Context(suggested: [Self.suggestion()])
        #expect(Self.causes(record, in: context) == [.videoDecodedNothing, .suggestedFix, .threadSpin, .droppedShader])
        let driver = Self.record(exit: Self.crash) {
            $0.driver = "EasyAntiCheat.sys"
            $0.missingDLL = "MSVCP140.dll"
        }
        #expect(Self.causes(driver, in: context) == [.kernelDriver, .missingLibrary, .suggestedFix])
    }

    @Test
    func `a panel opens for a remedy unless muted, and for a report unless never asked`() {
        let record = Self.record(exit: Self.crash) {
            $0.threads = RunRecord.Threads(busy: 15, processors: 16, samples: 30)
        }
        let findings = RunDiagnosis.findings(for: record)
        #expect(RunDiagnosis.raised(findings).map(\.cause) == [.crashed, .threadSpin])
        #expect(RunDiagnosis.raised(findings, asksAfterBadEnding: false).map(\.cause) == [.threadSpin])
        #expect(RunDiagnosis.raised(findings, quiet: [.threadSpin]).map(\.cause) == [.crashed])
        #expect(RunDiagnosis.raised(findings, quiet: [.threadSpin], asksAfterBadEnding: false).isEmpty)
        // Nothing known and a hang the user ended never open one by themselves.
        #expect(RunDiagnosis.raised(RunDiagnosis.findings(for: Self.record())).isEmpty)
        let ended = Self.record(exit: RunRecord.Exit(kind: .endedNotResponding, code: nil))
        #expect(RunDiagnosis.raised(RunDiagnosis.findings(for: ended)).isEmpty)
        // A kernel driver has no action and still opens one.
        let driver = Self.record { $0.driver = "EasyAntiCheat.sys" }
        #expect(RunDiagnosis.raised(RunDiagnosis.findings(for: driver), asksAfterBadEnding: false).map(\.cause) == [.kernelDriver])
    }

    @Test
    func `a cause is muted per game exactly when its finding is more than the report`() {
        for panel in RunDiagnosisFixtures.causes {
            guard let finding = panel.findings.first else { continue }
            let muted = Preferences.quietAppsKey(for: finding.cause) != nil
            #expect(muted == (finding.action != .sendReport), "\(finding.cause.rawValue)")
        }
        let keys = RunDiagnosis.Cause.allCases.compactMap(Preferences.quietAppsKey)
        #expect(Set(keys).count == keys.count)
        // The two mutes released apps already wrote keep their keys.
        #expect(Preferences.quietAppsKey(for: .threadSpin) == "quietThreadSpinApps")
        #expect(Preferences.quietAppsKey(for: .videoDecodedNothing) == "quietVideoDecodingApps")
    }

    // MARK: - Words and fixtures

    @Test
    func `every cause has a fixture that it leads, with a sentence and evidence`() {
        #expect(RunDiagnosisFixtures.causes.map(\.id) == RunDiagnosis.order.map(\.rawValue))
        for panel in RunDiagnosisFixtures.causes {
            let first = panel.findings.first
            #expect(first?.cause.rawValue == panel.id, "\(panel.id) is led by \(first?.cause.rawValue ?? "nothing")")
            #expect(first?.sentence.hasSuffix(".") == true, "\(panel.id)")
            #expect(first?.evidence.isEmpty == false, "\(panel.id)")
            #expect(first?.sentence.contains(panel.record.name ?? "?") == true, "\(panel.id) names its game")
            #expect(first?.brief.contains(panel.record.name ?? "?") == false, "\(panel.id) in a row says it")
        }
        #expect(RunDiagnosisFixtures.several.findings.count > 1)
    }

    @Test
    func `every word a finding shows has Simplified Chinese`() throws {
        let catalog = try Self.stringCatalog()
        for key in Self.findingKeys {
            #expect(catalog[key]?.isEmpty == false, "no Simplified Chinese for “\(key)”")
        }
    }

    /// The catalog keys ``RunDiagnosis`` builds its sentences, evidence and
    /// labels from, as `String(localized:)` spells an interpolation.
    private static let findingKeys = [
        "%@ needs a Windows kernel driver, which cannot run on a Mac.",
        "%@ failed to load, and the game drew nothing.",
        "%@ could not start without %@.",
        "No package Sevoflurane installs carries %@.",
        "%@ includes %@.",
        "Install (%@)",
        "Install",
        "%@ shows a blank picture where a video should play.",
        "The Mac\u{2019}s hardware decoder returned none of %lld %@ frames.",
        "The software decoders returned none of %lld %@ frames.",
        "Use Software Decoding",
        "Use Hardware Decoding",
        "The hardware decoder returned none of this game\u{2019}s video frames in a run on this Mac.",
        "The software decoders returned none of this game\u{2019}s video frames in a run on this Mac.",
        "%@ also fails on %@ on other Macs.",
        "%@ also fails on other Macs with these settings.",
        "1 Mac",
        "%lld Macs",
        "%@: %lld of %lld runs failed without the change, %lld of %lld with it.",
        "%@: %lld of %lld runs failed on %@, %lld of %lld on %@.",
        "Set %@ to %@",
        "Apply Suggested Fix",
        "%@ failed while starting and never drew a window.",
        "Unity quit with status 1. Its Player.log, in the report, says why.",
        "%@ crashed in the game\u{2019}s own code.",
        "Unreal quit with status 3 and wrote a callstack, which the report carries.",
        "%@ froze, and Sevoflurane ended it.",
        "Its last stall lasted %lld s and nothing got it moving.",
        "Nothing got it moving again.",
        "%@ stopped unexpectedly.",
        "%@ (%@) in %@",
        "%@ (%@)",
        "Exit status %lld",
        "An unhandled exception",
        "%@, %@ in.",
        "%@ quit with an error while starting.",
        "Exit status %@ after %@, before any window.",
        "Exit status %@ after %@.",
        "Exit status %@.",
        "%@ stopped answering, and you ended it.",
        "Its window took no clicks, keys or its close button.",
        "%@ kept %lld threads busy the whole time, which slows its picture.",
        "Its workers never rest on %lld processors. Told of %lld, they sleep.",
        "Limit to %lld Processors",
        "A run on this Mac kept a worker spinning on every processor.",
        "A run on this Mac could not start without a library this package carries.",
        "Processor limit",
        "Video decoding",
        "%@ is missing part of its picture.",
        "DXMT could not convert a shader to Metal, so a pass never ran.",
        "Choose Another Renderer",
        "Nothing in this run of %@ points at a problem.",
        "The game", "the game", "It", "it",
        "%lld s", "%lld min",
        "Access violation", "Stack overflow", "Illegal instruction", "Division by zero",
        "Stack buffer overrun", "Missing library", "C++ exception", "Exception",
    ]

    private static func stringCatalog() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sevoflurane/Localizable.xcstrings")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        return catalog.strings.mapValues { $0.localizations?["zh-Hans"]?.stringUnit?.value ?? "" }
    }

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable {
                    let value: String
                }

                let stringUnit: Unit?
            }

            let localizations: [String: Localization]?
        }

        let strings: [String: Entry]
    }
}

/// What the Wine log says a run lacked.
struct RunEvidenceTests {
    @Test
    func `the library a program's own executable imports is the one it lacked`() {
        let log = #"""
        0124:err:module:import_dll Library steam_api64.dll (which is needed by L"C:\\other\\tool.exe") not found
        0124:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\game\\Game.exe") not found
        0124:err:module:import_dll Library WDFLDR.SYS (which is needed by L"C:\\windows\\system32\\drivers\\HoYoKProtect.sys") not found
        """#
        #expect(MissingLibrary.all(in: log).map(\.library) == ["steam_api64.dll", "MSVCP140.dll"])
        #expect(MissingLibrary.library(forExecutable: "game.exe", endedDLLNotFound: false, in: log) == "MSVCP140.dll")
        // Another program's missing import says nothing about this one.
        #expect(MissingLibrary.library(forExecutable: "else.exe", endedDLLNotFound: false, in: log) == nil)
        #expect(MissingLibrary.library(forExecutable: nil, endedDLLNotFound: false, in: log) == nil)
        // A run that ended on the loader's own status takes the last one named.
        #expect(MissingLibrary.library(forExecutable: nil, endedDLLNotFound: true, in: log) == "MSVCP140.dll")
        #expect(MissingLibrary.library(forExecutable: "game.exe", endedDLLNotFound: true, in: "") == nil)
    }

    @Test
    func `a library that lacked another leads to the one that is missing`() {
        let log = #"""
        0124:err:module:import_dll Library winemetal.dll (which is needed by L"C:\\windows\\system32\\dxgi.dll") not found
        0124:err:module:import_dll Library dxgi.dll (which is needed by L"C:\\game\\Game.exe") not found
        """#
        #expect(MissingLibrary.library(forExecutable: "Game.exe", endedDLLNotFound: false, in: log) == "winemetal.dll")
    }

    private static func record(exe: String? = "Game.exe", fps: RunRecord.FrameRate? = nil) -> RunRecord {
        RunRecord(
            t: "2026-11-23T10:00:00Z", appid: 413_150, exe: exe, engine: "dormison-r14", renderer: "dxmt",
            runner: "wine", windows: "fixed", msync: true, macos: "27.0", fps: fps,
            host: RunRecord.Host(thermal: "nominal", load: 1),
        )
    }

    private static let driverFailed = #"""
    sevo:run pid=4100 exe=Game.exe appid=413150 engine=dormison-r17
    0124:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Driver\\EasyAntiCheat": c0000142
    """#

    @Test
    func `a run that drew nothing keeps the driver that failed, and one that drew does not`() {
        #expect(RunInProgress.failedDriver(of: Self.record(), in: Self.driverFailed) == "EasyAntiCheat.sys")
        // The game's own process, started under its app id by a launcher of another name, drew.
        let drew = Self.driverFailed + "\nsevo:gfx pid=4100 first present +5210ms surface=0x1 layer=on-screen"
        #expect(RunInProgress.failedDriver(of: Self.record(exe: "Launcher.exe"), in: drew) == nil)
        #expect(KernelDriverFailure.outcome(in: drew, program: "Launcher.exe") == .driverFailed("EasyAntiCheat.sys"))
        #expect(KernelDriverFailure.outcome(in: drew, program: "Launcher.exe", appID: 413_150) == .presented)
        // The present counter saw frames, whatever the log's tail kept.
        let counted = RunRecord.FrameRate(avg: 60, low1: 40, samples: 12)
        #expect(RunInProgress.failedDriver(of: Self.record(fps: counted), in: Self.driverFailed) == nil)
        // The driver the helper's watch named stands when the tail has lost its line.
        var named = Self.record()
        named.driver = "HoYoKProtect.sys"
        #expect(RunInProgress.failedDriver(of: named, in: "") == "HoYoKProtect.sys")
        named.fps = counted
        #expect(RunInProgress.failedDriver(of: named, in: "") == nil)
    }

    @Test
    func `the two facts survive a round trip and stay out of the shared run`() throws {
        var record = Self.record()
        record.driver = "EasyAntiCheat.sys"
        record.missingDLL = "MSVCP140.dll"
        record.durationSeconds = 12
        record.exit = RunRecord.Exit(kind: .crash, code: 3)
        let encoded = try JSONEncoder().encode(record)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["driver"] as? String == "EasyAntiCheat.sys")
        #expect(json["missing_dll"] as? String == "MSVCP140.dll")
        #expect(try JSONDecoder().decode(RunRecord.self, from: encoded) == record)
        if let shared = SharedRun(record: record, appVersion: "1.0 (1)") {
            let sent = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as? [String: Any])
            #expect(sent["driver"] == nil)
            #expect(sent["missing_dll"] == nil)
        }
    }
}
