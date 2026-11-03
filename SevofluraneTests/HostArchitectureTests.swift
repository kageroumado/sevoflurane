import Foundation
import MachO
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

    /// An engine folder whose `wine/bin/wineserver` is a bare Mach-O header
    /// for `types`: thin for one, universal for more.
    private func engine(serverTypes types: [cpu_type_t]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-arch-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        var bytes = Data()
        func append(_ value: some Any) { withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) } }
        if types.count == 1 {
            append(MH_MAGIC_64)
            append(types[0])
        } else {
            append(FAT_MAGIC.bigEndian)
            append(UInt32(types.count).bigEndian)
            for type in types {
                append(type.bigEndian)
                append(Int32(0).bigEndian)
                append(UInt32(0x4000).bigEndian)
                append(UInt32(0x100).bigEndian)
                append(UInt32(14).bigEndian)
            }
        }
        try bytes.write(to: bin.appendingPathComponent("wineserver"))
        return root
    }

    @Test
    func `the Mach-O reader names every slice`() throws {
        let fat = try engine(serverTypes: [CPU_TYPE_X86_64, CPU_TYPE_ARM64])
        defer { try? FileManager.default.removeItem(at: fat) }
        #expect(MachOIdentity.cpuTypes(ofFile: fat.appendingPathComponent("wine/bin/wineserver")) == [CPU_TYPE_X86_64, CPU_TYPE_ARM64])
        #expect(MachOIdentity.cpuTypes(ofFile: fat.appendingPathComponent("wine/bin/missing")) == nil)
    }

    @Test
    func `an Intel Mac runs only an engine whose wineserver has an x86_64 slice`() throws {
        let arm64Only = try engine(serverTypes: [CPU_TYPE_ARM64])
        let universal = try engine(serverTypes: [CPU_TYPE_X86_64, CPU_TYPE_ARM64])
        let x86Only = try engine(serverTypes: [CPU_TYPE_X86_64])
        defer { for url in [arm64Only, universal, x86Only] { try? FileManager.default.removeItem(at: url) } }

        #expect(!Engine.serverRuns(inEngineAt: arm64Only, appleSilicon: false))
        #expect(Engine.serverRuns(inEngineAt: universal, appleSilicon: false))
        #expect(Engine.serverRuns(inEngineAt: x86Only, appleSilicon: false))
        for root in [arm64Only, universal, x86Only] {
            #expect(Engine.serverRuns(inEngineAt: root, appleSilicon: true))
        }
    }

    @Test
    func `a server with no readable header is left to fail at launch`() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("host-arch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Engine.serverRuns(inEngineAt: root, appleSilicon: false))
    }
}
