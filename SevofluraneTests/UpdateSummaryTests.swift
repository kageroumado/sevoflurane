import Foundation
import Testing
@testable import Sevoflurane

/// What the popover's gear says is waiting. The comparison is the whole
/// thing: a version string is read the way a person reads it, and "newer"
/// means newer than everything this Mac already has.
@MainActor
struct UpdateSummaryTests {
    private func manifest(
        stable: String, dxmt: [String] = [],
    ) throws -> EngineManifest {
        let components = dxmt.map {
            """
            {"version": "\($0)", \
            "url": "https://github.com/3Shain/dxmt/releases/download/v\($0)/dxmt-v\($0)-builtin.tar.gz", \
            "sha256": null, "notes": "run with \(stable)"}
            """
        }.joined(separator: ",")
        return try EngineManifest.decode(Data("""
        {
          "schema": 2,
          "channels": {"stable": {
            "version": "\(stable)", "minAppVersion": "1.0",
            "url": "https://github.com/kageroumado/dormison/releases/download/r0/\(stable).tar.xz",
            "sha256": "694477832c85da7bfa09793029eae182cd2aafd2bfe819c91888ec39be6e93be",
            "sizeBytes": 1, "notes": null
          }},
          "components": {"dxmt": [\(components)]}
        }
        """.utf8))
    }

    @Test
    func `a release past everything installed is what is waiting`() throws {
        let feed = try manifest(stable: "dormison-r12")
        #expect(UpdateSummary.newerEngine(
            in: feed, installed: ["dormison-r9", "dormison-r11"],
        ) == "Dormison r12")
    }

    /// `dormison-r9` sorts after `dormison-r11` as plain text, which is how
    /// an up-to-date Mac ends up being told to update.
    @Test
    func `a two-digit release beats a one-digit one`() throws {
        let feed = try manifest(stable: "dormison-r9")
        #expect(UpdateSummary.newerEngine(in: feed, installed: ["dormison-r11"]) == nil)
    }

    @Test
    func `the installed release itself is not waiting`() throws {
        let feed = try manifest(stable: "dormison-r11")
        #expect(UpdateSummary.newerEngine(in: feed, installed: ["dormison-r11"]) == nil)
    }

    /// The engine picker already offers to fetch one, and saying it twice
    /// would be the first thing a CrossOver user sees.
    @Test
    func `a Mac with no managed engine is told nothing`() throws {
        let feed = try manifest(stable: "dormison-r12")
        #expect(UpdateSummary.newerEngine(in: feed, installed: []) == nil)
    }

    @Test
    func `a component is waiting only when everything here is older`() {
        #expect(UpdateSummary.newerVersion(tested: ["0.80", "0.81"], have: ["0.80"]) == "0.81")
        #expect(UpdateSummary.newerVersion(tested: ["0.81"], have: ["0.81", "0.80"]) == nil)
        #expect(UpdateSummary.newerVersion(tested: ["0.80"], have: ["0.81"]) == nil)
    }

    /// An engine that declares no version of a component, with none added
    /// beside it, gives nothing to compare against.
    @Test
    func `a component with nothing to compare against says nothing`() {
        #expect(UpdateSummary.newerVersion(tested: ["0.81"], have: []) == nil)
        #expect(UpdateSummary.newerVersion(tested: [], have: ["0.80"]) == nil)
    }

    @Test
    func `versions read the way a person reads them`() {
        #expect(UpdateSummary.isNewer("0.81", thanAll: ["0.80", "0.9"]))
        #expect(!UpdateSummary.isNewer("0.9", thanAll: ["0.80"]))
        #expect(UpdateSummary.newest(of: ["1.10.3-20230507-repack", "1.9.0"])
            == "1.10.3-20230507-repack")
        #expect(UpdateSummary.newest(of: []) == nil)
    }
}
