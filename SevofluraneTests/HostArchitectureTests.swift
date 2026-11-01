import Foundation
import Testing
@testable import Sevoflurane

/// What changes between an Apple silicon Mac and an Intel one: Rosetta is
/// not asked for, and D3DMetal, Apple's toolkit for Apple GPUs, is not offered.
struct HostArchitectureTests {
    @Test
    func `the predicate reads the machine, whichever slice runs`() {
        var machine = utsname()
        uname(&machine)
        let arm64 = withUnsafeBytes(of: machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "arm64"
        // Under Rosetta uname says x86_64 while the Mac is Apple silicon; the
        // predicate must not follow uname there.
        #expect(MacHardware.isAppleSilicon == arm64 || MacHardware.isAppleSilicon)
    }

    @Test
    func `D3DMetal is offered on Apple silicon alone`() {
        #expect(Renderer.hostable(onAppleSilicon: true) == Renderer.allCases)
        #expect(Renderer.hostable(onAppleSilicon: false) == Renderer.allCases.filter { $0 != .d3dmetal })
        #expect(Renderer.hostable(onAppleSilicon: false).contains(.dxmt))
        #expect(Renderer.hostable(onAppleSilicon: false).contains(.wined3d))
    }

    @Test
    func `the renderer row offers only what this Mac can host`() {
        let offered = SettingCatalog.setting(.renderer).control
        guard case let .choices(choices) = offered else { Issue.record("renderer row is not a choice list"); return }
        let names = Set(choices.map(\.value))
        #expect(names.contains(Renderer.d3dmetal.rawValue) == MacHardware.isAppleSilicon)
        #expect(names.contains(Renderer.dxmt.rawValue))
    }
}
