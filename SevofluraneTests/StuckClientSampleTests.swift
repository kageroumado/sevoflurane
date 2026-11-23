import Foundation
import Testing
@testable import Sevoflurane

/// What is kept of a client that stopped answering: which processes are
/// sampled, the Wine log's end, Steam's dumps, the fault the log names, and
/// the disk the episodes may take.
struct StuckClientSampleTests {
    // MARK: - The fault Wine's log names

    /// The lines Wine's log held at the wedge of 2026-11-17 16:03: the last
    /// jump-list builds, the RPC server thread's failure, the sweep.
    private static let rpcWedge = #"""
    ==== 2026-11-16T00:50:05Z client (WINEDEBUG=err+all,+pid)
    ==== 2026-11-16T00:50:06Z sevo-discord-bridge.exe (WINEDEBUG=err+all,+pid)
    sevo:presenter pid=39806 surface: no display link; frames are not presented
    0028:04d4:fixme:shell:CustomDestinationList_SetAppID 000000001FA3ECD0 (L"Valve.Steam.Client"): stub
    0028:0158:err:rpc:rpcrt4_protseq_np_wait_for_new_connection wait failed with error 87
    sevo:msync sweep objects=3562 available=1852 lost-wakes=0
    sevo:msync backstop exit pid=017c exe=steamservice.exe objects=50 woke=1 133:manual-event
    """#

    /// The lines at the wedge of 2026-11-16 01:48, when Forts exited with the
    /// overlay's process up.
    private static let serviceAbort = #"""
    ==== 2026-11-15T22:05:24Z client (WINEDEBUG=err+all,+pid)
    sevo:exit pid=22212 wpid=0664 windows closed
    sevo:gfx pid=22212 exit presents=321056
    wine: Call from 000000007BE150F8 to unimplemented function GDI32.dll.D3DKMTSetProcessSchedulingPriorityClass, aborting
    wine: Call from 7BE150F8 to unimplemented function GDI32.dll.D3DKMTSetProcessSchedulingPriorityClass, aborting
    sevo:gfx pid=22230 exit presents=0
    sevo:msync backstop exit pid=0180 exe=steamservice.exe objects=60 woke=2 133:manual-event 2865:manual-event
    src\clientdll\steamengine.cpp (2753) : Assertion Failed: CSteamEngine::BMainLoop appears to have stalled > 15 seconds without event signalled
    sevo:msync sweep objects=3441 available=1792 lost-wakes=0
    """#

    @Test
    func `the RPC listener limit is named from its line`() {
        #expect(StuckClientFault.faults(in: Self.rpcWedge) == [.rpcListenerLimit])
    }

    @Test
    func `an aborted process and Steam's own watchdog are named once each, in the log's order`() {
        #expect(StuckClientFault.faults(in: Self.serviceAbort) == [
            .unimplementedFunction("GDI32.dll.D3DKMTSetProcessSchedulingPriorityClass"),
            .engineLoopStalled,
        ])
    }

    @Test
    func `a fault of the client before this one is not this client's`() {
        // The client restarted after the wedge; its log holds nothing known since.
        let restarted = Self.rpcWedge + """
        
        ==== 2026-11-17T15:04:46Z client (WINEDEBUG=err+all,+pid)
        sevo:run pid=40112 exe=Steam.exe appid=none engine=dormison-r12 swift=9ac4d8f79dcf06aa wpid=0028
        """
        #expect(StuckClientFault.faults(in: restarted).isEmpty)
        #expect(StuckClientFault.clientSession(of: restarted).contains("pid=40112"))
        // A tail that begins after the client's header is all one session.
        let headless = Self.rpcWedge.split(separator: "\n").dropFirst(2).joined(separator: "\n")
        #expect(StuckClientFault.faults(in: headless) == [.rpcListenerLimit])
        #expect(StuckClientFault.faults(in: "").isEmpty)
    }

    @Test
    func `every fault has a sentence for the event log`() {
        #expect(StuckClientFault.rpcListenerLimit.sentence.contains("64-listener limit"))
        #expect(StuckClientFault.unimplementedFunction("GDI32.dll.X").sentence
            == "a process aborted on GDI32.dll.X, a function Wine does not implement")
        #expect(StuckClientFault.engineLoopStalled.sentence.contains("watchdog"))
    }

    // MARK: - Which processes

    @Test
    func `the client comes first, then the web helper's browser process, then the rest`() {
        let helpers: [(pid: pid_t, commandLine: String?)] = [
            (501, #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=renderer --lang=en-US"#),
            (400, #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=gpu-process"#),
            (300, #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe -lang=en_US -steampath=C:\Program Files (x86)\Steam\Steam.exe"#),
            (450, #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=utility --utility-sub-type=network.mojom.NetworkService"#),
            (500, #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=renderer"#),
            (600, nil),
            // `pgrep -if steam.exe` names the client among the helpers; it is sampled once.
            (100, #"C:\Program Files (x86)\Steam\Steam.exe -silent -nocrashdialog"#),
        ]
        let targets = StuckClientSample.targets(client: [100], helpers: helpers)
        // The helper whose command line cannot be read sorts with the renderers, past the sixth place.
        #expect(targets.map(\.pid) == [100, 300, 400, 450, 500, 501])
        #expect(targets.map(\.label) == [
            "steam", "webhelper-browser", "webhelper-gpu-process", "webhelper-utility", "webhelper-renderer",
            "webhelper-renderer",
        ])
        #expect(targets.count == StuckClientSample.mostProcesses)
        #expect(StuckClientSample.helperLabel(commandLine: nil) == "webhelper")
        #expect(targets[0].report == "steam-100.txt")
        #expect(StuckClientSample.targets(client: [], helpers: []).isEmpty)
    }

    // MARK: - What is kept beside the samples

    /// A scratch root, Wine log and dumps folder, removed at the test's end.
    private final class Scratch {
        let directory: URL
        let places: StuckClientSample.Places

        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "stuck-client-\(UUID().uuidString)")
            places = StuckClientSample.Places(
                root: directory.appending(path: "episodes"),
                wineLog: directory.appending(path: "wine.log"),
                dumps: directory.appending(path: "dumps"),
            )
            try FileManager.default.createDirectory(at: places.root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: places.dumps, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// Makes an episode's folder holding each sample at `bytes`.
        func episode(
            _ probe: StuckClientSample.Probe, at date: Date, samples: [String] = [], bytes: Int = 0,
        ) throws -> URL {
            let folder = StuckClientSample.episodeFolder(probe, at: date, in: places.root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for sample in samples {
                try Data(count: bytes).write(to: folder.appending(path: sample))
            }
            return folder
        }

        func dump(_ name: String, written: Date, bytes: Int = 1024) throws {
            let file = places.dumps.appending(path: name)
            try Data(count: bytes).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
        }
    }

    private static let began = Date(timeIntervalSince1970: 1_795_000_000)
    private static let steam = "steam-100.txt.gz"
    private static let browser = "webhelper-browser-300.txt.gz"
    /// A report `gzip` did not finish stays as `sample` wrote it.
    private static let renderer = "webhelper-renderer-500.txt"

    @Test
    func `the Wine log's end is kept from the start of a line`() throws {
        let scratch = try Scratch()
        let lines = (0 ..< 400).map { "line \($0) of the log" }
        try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: scratch.places.wineLog)
        let tail = try #require(StuckClientSample.wineTail(of: scratch.places.wineLog, bytes: 1000))
        let kept = String(decoding: tail, as: UTF8.self).split(separator: "\n")
        #expect(tail.count <= 1000)
        #expect(kept.first?.hasPrefix("line ") == true)
        #expect(kept.last == "line 399 of the log")
        #expect(lines.suffix(kept.count).elementsEqual(kept.map(String.init)))
        // A log shorter than the tail is kept whole, an empty or missing one is nothing.
        let whole = try #require(StuckClientSample.wineTail(of: scratch.places.wineLog, bytes: 1 << 20))
        #expect(String(decoding: whole, as: UTF8.self).hasPrefix("line 0 of the log\n"))
        try Data().write(to: scratch.places.wineLog)
        #expect(StuckClientSample.wineTail(of: scratch.places.wineLog) == nil)
        #expect(StuckClientSample.wineTail(of: scratch.directory.appending(path: "none.log")) == nil)
    }

    @Test
    func `only the dumps Steam wrote during the episode are kept, newest first`() throws {
        let scratch = try Scratch()
        let since = Self.began.addingTimeInterval(-StuckClientSample.lead)
        try scratch.dump("assert_steam.exe_20261116014850_1.dmp", written: Self.began.addingTimeInterval(-60))
        try scratch.dump("assert_steam.exe_20261116014905_2.dmp", written: Self.began.addingTimeInterval(20))
        // Last week's dump, a web helper's crash and a dump too large to copy stay where they are.
        try scratch.dump("assert_steam.exe_20261109193500_1.dmp", written: Self.began.addingTimeInterval(-600_000))
        try scratch.dump("crash_steamwebhelper.exe_20261116014851_3.dmp", written: Self.began)
        try scratch.dump(
            "assert_steam.exe_20261116014906_4.dmp", written: Self.began, bytes: StuckClientSample.largestDump + 1,
        )
        #expect(StuckClientSample.dumps(in: scratch.places.dumps, writtenSince: since).map(\.lastPathComponent) == [
            "assert_steam.exe_20261116014905_2.dmp", "assert_steam.exe_20261116014850_1.dmp",
        ])
        // A stall that leaves many dumps keeps the newest few.
        for index in 0 ..< 6 {
            try scratch.dump(
                "assert_steam.exe_2026111602000\(index)_1.dmp", written: Self.began.addingTimeInterval(100 + Double(index)),
            )
        }
        let newest = StuckClientSample.dumps(in: scratch.places.dumps, writtenSince: since)
        #expect(newest.count == StuckClientSample.mostDumps)
        #expect(newest.first?.lastPathComponent == "assert_steam.exe_20261116020005_1.dmp")
        #expect(StuckClientSample.dumps(in: scratch.directory.appending(path: "none"), writtenSince: since).isEmpty)
    }

    @Test
    func `an episode keeps the log's end and the dumps beside its samples, and names the fault`() throws {
        let scratch = try Scratch()
        try Data(Self.rpcWedge.appending("\n").utf8).write(to: scratch.places.wineLog)
        try scratch.dump("assert_steam.exe_20261117160330_1.dmp", written: Self.began.addingTimeInterval(15))
        let folder = try scratch.episode(.devTools, at: Self.began, samples: [Self.steam, Self.browser], bytes: 4096)

        let kept = StuckClientSample.keepEvidence(
            in: folder, samples: [Self.steam, Self.browser], began: Self.began, places: scratch.places,
        )
        #expect(kept.samples == [Self.steam, Self.browser])
        #expect(kept.samplesDropped == 0)
        #expect(kept.wineTailBytes == Self.rpcWedge.utf8.count + 1)
        #expect(kept.dumps == ["assert_steam.exe_20261117160330_1.dmp"])
        #expect(kept.faults == [.rpcListenerLimit])
        #expect(kept.episodesDropped == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == [
            "assert_steam.exe_20261117160330_1.dmp", "steam-100.txt.gz", "webhelper-browser-300.txt.gz", "wine-tail.log",
        ])
        #expect(try String(contentsOf: folder.appending(path: "wine-tail.log"), encoding: .utf8) == Self.rpcWedge + "\n")

        let lines = StuckClientSample.lines(describing: kept)
        #expect(lines.count == 2)
        #expect(lines[0] == "kept of the stuck client in \(folder.path): "
            + "samples steam-100.txt.gz, webhelper-browser-300.txt.gz; "
            + "the Wine log's last 1 KB; Steam's assert_steam.exe_20261117160330_1.dmp")
        #expect(lines[1] == "the Wine log since this client started names a known fault: "
            + StuckClientFault.rpcListenerLimit.sentence)
    }

    @Test
    func `an episode with nothing to keep says so`() throws {
        let scratch = try Scratch()
        let folder = try scratch.episode(.mainThread, at: Self.began)
        let kept = StuckClientSample.keepEvidence(in: folder, samples: [], began: Self.began, places: scratch.places)
        #expect(kept == StuckClientSample.Kept(folder: folder))
        #expect(StuckClientSample.lines(describing: kept) == [
            "kept nothing of the stuck client: no sample, log or dump could be written to \(folder.path)",
        ])
    }

    // MARK: - Disk

    @Test
    func `an episode over its bound loses its least telling samples and keeps the log and dumps`() throws {
        let scratch = try Scratch()
        try Data("wine: a line\n".utf8).write(to: scratch.places.wineLog)
        try scratch.dump("assert_steam.exe_20261117160330_1.dmp", written: Self.began)
        let samples = [Self.steam, Self.browser, Self.renderer]
        let folder = try scratch.episode(.devTools, at: Self.began, samples: samples, bytes: 40000)

        // Three samples of 40,000 bytes, a 1,024-byte dump and a line of log against 100,000.
        let kept = StuckClientSample.keepEvidence(
            in: folder, samples: samples, began: Self.began, places: scratch.places, within: 100_000,
        )
        #expect(kept.samples == [Self.steam, Self.browser])
        #expect(kept.samplesDropped == 1)
        #expect(StuckClientSample.size(of: folder) == 80000 + 1024 + 13)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == [
            "assert_steam.exe_20261117160330_1.dmp", "steam-100.txt.gz", "webhelper-browser-300.txt.gz", "wine-tail.log",
        ])
        #expect(StuckClientSample.lines(describing: kept).contains("removed 1 sample(s) to keep the episode within 32 MB"))

        // A bound the log and the dump alone pass removes every sample and stops there.
        let later = try scratch.episode(
            .devTools, at: Self.began.addingTimeInterval(60), samples: [Self.steam, Self.browser], bytes: 40000,
        )
        let bare = StuckClientSample.keepEvidence(
            in: later, samples: [Self.steam, Self.browser], began: Self.began, places: scratch.places, within: 100,
        )
        #expect(bare.samples.isEmpty)
        #expect(bare.samplesDropped == 2)
        #expect(bare.wineTailBytes == 13)
        #expect(bare.dumps == ["assert_steam.exe_20261117160330_1.dmp"])
    }

    @Test
    func `the oldest episodes go first once all of them pass the bound, never the one just kept`() throws {
        let scratch = try Scratch()
        let folders = try (0 ..< 4).map { index in
            try scratch.episode(
                index.isMultiple(of: 2) ? .devTools : .mainThread, at: Self.began.addingTimeInterval(Double(index) * 3600),
                samples: [Self.steam], bytes: 1000,
            )
        }
        // Four episodes of 1,000 bytes against a bound of 2,500: the two oldest go.
        #expect(StuckClientSample.groom(scratch.places.root, keeping: folders[3], within: 2500) == 2)
        var left = try FileManager.default.contentsOfDirectory(atPath: scratch.places.root.path).sorted()
        #expect(left == folders[2...].map(\.lastPathComponent))
        // Within the bound nothing goes.
        #expect(StuckClientSample.groom(scratch.places.root, keeping: folders[3], within: 2500) == 0)
        // The episode just kept stays even when it alone passes the bound.
        #expect(StuckClientSample.groom(scratch.places.root, keeping: folders[3], within: 10) == 1)
        left = try FileManager.default.contentsOfDirectory(atPath: scratch.places.root.path)
        #expect(left == [folders[3].lastPathComponent])
        // A file beside the episodes is left alone.
        try Data(count: 5000).write(to: scratch.places.root.appending(path: "notes.txt"))
        #expect(StuckClientSample.groom(scratch.places.root, keeping: folders[3], within: 10) == 0)
        #expect(FileManager.default.fileExists(atPath: scratch.places.root.appending(path: "notes.txt").path))
    }

    @Test
    func `episode folders sort by when they were captured, whichever probe found them`() throws {
        let root = URL(filePath: "/logs/Sevoflurane-stuck-steam")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 3, minute: 45, second: 17)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 20, minute: 10, second: 2)))
        let first = StuckClientSample.episodeFolder(.mainThread, at: morning, in: root)
        let second = StuckClientSample.episodeFolder(.devTools, at: evening, in: root)
        #expect(first.lastPathComponent == "2026-11-20T034517-main-thread")
        #expect(second.lastPathComponent == "2026-11-20T201002-devtools")
        #expect(first.lastPathComponent < second.lastPathComponent)
    }

    @Test
    func `the bounds hold a restart back for half a minute at most and the disk to 128 MB`() {
        // Each subprocess is ended at its timeout and given five seconds to be reaped.
        let longest = StuckClientSample.sampleTimeout + StuckClientSample.compressTimeout + .seconds(10)
        #expect(longest <= .seconds(30))
        #expect(Duration.seconds(StuckClientSample.seconds) < StuckClientSample.sampleTimeout)
        // The log's end and the dumps fit an episode with room for a sample left uncompressed.
        #expect(StuckClientSample.tailBytes + StuckClientSample.mostDumps * StuckClientSample.largestDump
            + (14 << 20) < StuckClientSample.episodeBytes)
        #expect(StuckClientSample.episodeBytes == 32 << 20)
        #expect(StuckClientSample.totalBytes == 128 << 20)
    }

    // MARK: - Compressing a report

    /// A report as `sample` lays one out for a Wine thread: the same frame
    /// repeated one level deeper each line, which is what makes one 13 MB.
    private static let report = "Call graph:\n" + (0 ..< 500).map { depth in
        String(repeating: "  ", count: depth) + "1417 __wine_syscall_dispatcher  (in ntdll.so) + 396  [0x20872d94f]"
    }.joined(separator: "\n")

    @Test
    func `a report is kept compressed, under the name the episode records`() async throws {
        let scratch = try Scratch()
        let folder = try scratch.episode(.devTools, at: Self.began)
        let report = folder.appending(path: "steam-100.txt")
        try Data(Self.report.utf8).write(to: report)

        let kept = await StuckClientSample.compress(report)
        #expect(kept == Self.steam)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [Self.steam])
        let written = try Data(contentsOf: folder.appending(path: Self.steam))
        // A gzip member begins 1f 8b; the indentation is most of a report, so it shrinks at least tenfold.
        #expect(written.prefix(2) == Data([0x1F, 0x8B]))
        #expect(written.count * 10 < Self.report.utf8.count)
        // A process `sample` wrote nothing for has no report to keep.
        let none = await StuckClientSample.compress(folder.appending(path: "webhelper-renderer-500.txt"))
        #expect(none == nil)
    }
}
