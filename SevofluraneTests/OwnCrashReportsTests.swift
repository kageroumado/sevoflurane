import Foundation
import Testing
@testable import Sevoflurane

/// Which `.ips` files are crashes of this copy of Sevoflurane, and so go to
/// Digoxin at the crash-reports tier.
struct OwnCrashReportsTests {
    private static let identity = OwnCrashReports.Identity(
        bundleID: "glass.kagerou.sevoflurane",
        imageUUIDs: ["B864FA4D-DD06-3137-A1AF-4FF6634AA247"],
    )

    /// An `.ips` as macOS writes it: one JSON header line, then the body.
    private static func ips(bugType: String = "309", bundleID: String? = nil, sliceUUID: String) -> Data {
        var header: [String: Any] = [
            "app_name": "Sevoflurane", "bug_type": bugType, "slice_uuid": sliceUUID,
            "timestamp": "2026-10-05 02:05:31.00 +0200",
        ]
        header["bundleID"] = bundleID
        let line = try! JSONSerialization.data(withJSONObject: header)
        let body = Data(#"{"procPath" : "\/Users\/USER\/*\/Sevoflurane.app\/Contents\/MacOS\/Sevoflurane"}"#.utf8)
        return line + Data("\n".utf8) + body
    }

    @Test
    func `the apps crash is matched by its bundle identifier`() {
        let data = Self.ips(bundleID: "glass.kagerou.sevoflurane", sliceUUID: "00000000-0000-0000-0000-000000000001")
        #expect(OwnCrashReports.isCrash(data, of: Self.identity))
    }

    @Test
    func `a debug builds crash belongs to the debug build`() {
        let data = Self.ips(bundleID: "glass.kagerou.sevoflurane.debug", sliceUUID: "00000000-0000-0000-0000-000000000001")
        #expect(!OwnCrashReports.isCrash(data, of: Self.identity))
    }

    @Test
    func `the helpers crash is matched by its image UUID in any case`() {
        let data = Self.ips(bundleID: "glass.kagerou.sevoflurane.daemon", sliceUUID: "b864fa4d-dd06-3137-a1af-4ff6634aa247")
        #expect(OwnCrashReports.isCrash(data, of: Self.identity))
    }

    @Test
    func `another builds helper is not ours`() {
        let data = Self.ips(sliceUUID: "11111111-2222-3333-4444-555555555555")
        #expect(!OwnCrashReports.isCrash(data, of: Self.identity))
    }

    @Test
    func `a hang is not a crash`() {
        let data = Self.ips(bugType: "409", bundleID: "glass.kagerou.sevoflurane", sliceUUID: "x")
        #expect(!OwnCrashReports.isCrash(data, of: Self.identity))
    }

    @Test
    func `something that is not an IPS file is not a crash`() {
        #expect(!OwnCrashReports.isCrash(Data("not json\n{}".utf8), of: Self.identity))
        #expect(!OwnCrashReports.isCrash(Data(), of: Self.identity))
    }

    @Test
    func `the running identity names the app and its own image`() throws {
        let running = OwnCrashReports.Identity.running
        #expect(running.bundleID == Bundle.main.bundleIdentifier)
        let own = try #require(MachOIdentity.ofThisProcess)
        #expect(running.imageUUIDs.contains(own))
    }
}
