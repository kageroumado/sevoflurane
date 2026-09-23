import Foundation
import Testing
@testable import Sevoflurane

/// The WINEDEBUG channels a launch carries, and how Debug mode folds its own
/// set together with a bottle's `wine-debug` channels instead of replacing
/// them — `debug.env` is read after `bottle.env`, so a bare level-one set
/// would drop a `+d3d` set by hand.
struct WineLogChannelCompositionTests {
    /// Debug off, custom channels set: no fold happens. `bottle.env` carries
    /// the bottle's channels verbatim and no `debug.env` exists, so a launch
    /// carries exactly what was set — ``WineLog/effectiveChannels(debugMode:)``
    /// returns the channels unchanged when the mode is off.
    @Test
    func `debug off carries the custom channels unfolded`() {
        // The composition is Debug mode's alone; with the mode off the bottle
        // string is authoritative as written. The effective set is `channels`
        // itself, not a fold of it — the same string that lands in bottle.env.
        #expect(WineLog.effectiveChannels(debugMode: false) == WineLog.channels)
    }

    /// Debug on, custom channels set: Debug mode's always-on and diagnostic
    /// channels, with the bottle's `+d3d` folded in and kept — the D6 case.
    @Test
    func `debug on folds the custom channels in without dropping any`() {
        let composed = WineLog.compose(WineLog.levelOne, with: "+d3d,err+all")
        #expect(composed == "err+all,+pid,+seh,+loaddll,+d3d")
        // Everything the mode needs and the channel the tester added are all
        // present, so a game produces trace:d3d lines.
        for token in ["err+all", "+pid", "+seh", "+loaddll", "+d3d"] {
            #expect(composed.split(separator: ",").contains { $0 == token }, "missing \(token)")
        }
    }

    /// Debug on, no custom channels: the mode's own level-one set, unchanged
    /// from folding the always-on default into it.
    @Test
    func `debug on with no custom set is the mode's own channels`() {
        #expect(WineLog.compose(WineLog.levelOne, with: WineLog.levelZero) == WineLog.levelOne)
    }

    /// A channel named on both sides takes the addition's token, so a tester
    /// can raise or lower a class the mode already set.
    @Test
    func `the addition wins where both name a channel`() {
        #expect(WineLog.compose("err+all,+seh", with: "warn+seh") == "err+all,warn+seh")
        #expect(WineLog.compose("err+all,+pid", with: "-pid") == "err+all,-pid")
    }

    /// A token's channel is the text after its sign, whichever class prefixes
    /// it, so `+seh` and `warn+seh` collapse to one entry.
    @Test
    func `a class prefix does not make a token a different channel`() {
        #expect(WineLog.compose("+seh", with: "trace+seh") == "trace+seh")
        #expect(WineLog.compose("fixme-heap", with: "+heap") == "+heap")
    }

    /// Empty and whitespace-padded tokens are dropped, so a stray comma cannot
    /// write an empty `WINEDEBUG` fragment the engine reads as an unset.
    @Test
    func `blank tokens are ignored`() {
        #expect(WineLog.compose("err+all, ,+pid", with: "") == "err+all,+pid")
        #expect(WineLog.compose("", with: "+d3d") == "+d3d")
    }
}

/// How the log survives its own rotation while other processes write to it.
struct WineLogRotationTests {
    @Test
    func `rotation keeps an inherited writer at the end of the file`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winelog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wine.log")

        let early = try #require(WineLog.handle(labeled: "client", at: url, rotatingOver: 1000))
        early.write(Data((String(repeating: "x", count: 2000) + "\n").utf8))
        // The next launch finds the file over the limit and truncates it while
        // the client still holds its descriptor.
        let late = try #require(WineLog.handle(labeled: "game", at: url, rotatingOver: 1000))
        early.write(Data("client line\n".utf8))
        try early.close()
        try late.close()

        let contents = try Data(contentsOf: url)
        #expect(!contents.contains(0))
        #expect(contents.count < 1000)
        #expect(String(decoding: contents, as: UTF8.self).hasSuffix("client line\n"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("wine.old.log").path))
    }
}
