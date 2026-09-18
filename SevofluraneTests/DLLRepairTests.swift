import Foundation
import Testing
@testable import Sevoflurane

/// A DLL a run said was missing, and the package that puts it back.
struct DLLRepairTests {
    @Test
    func `the 140-family files come from the Visual C++ redistributable`() throws {
        for name in ["VCRUNTIME140.dll", "msvcp140_1", "concrt140.DLL"] {
            let repair = try #require(KnownFixes.dllRepair(for: name))
            #expect(repair.dependency == "vcredist")
            #expect(repair.mode == "n,b")
            #expect(!repair.dll.contains(".dll"))
        }
    }

    @Test
    func `the numbered DirectX families come from the 2010 redistributable`() throws {
        for name in ["d3dx9_43.dll", "xinput1_3", "xaudio2_7", "d3dcompiler_43"] {
            let repair = try #require(KnownFixes.dllRepair(for: name))
            #expect(repair.dependency == "directx2010")
        }
        // The shader compiler is its own package, and its exact name wins over
        // the numbered family it sits beside.
        #expect(KnownFixes.dllRepair(for: "d3dcompiler_47")?.dependency == "d3dcompiler")
    }

    @Test
    func `a DLL no package carries has nothing to offer`() {
        #expect(KnownFixes.dllRepair(for: "steam_api64") == nil)
        #expect(KnownFixes.dllRepair(for: "") == nil)
    }

    @Test
    func `a repair is one game's load order, beside whatever it already had`() throws {
        let repair = try #require(KnownFixes.dllRepair(for: "xinput1_3.dll"))
        var values = ConfigValues.empty
        values.dllOverrides = ["d3d9": ""]
        KnownFixes.apply(repair, to: &values)
        #expect(values.dllOverrides == ["d3d9": "", "xinput1_3": "n,b"])
        #expect(repair.packageName.contains("DirectX"))
    }

    @Test
    func `every repair names a package the dependency catalog has`() {
        let ids = Set(BottleDependencies.catalog.map(\.id))
        for name in ["vcruntime140", "d3dcompiler_47", "d3dx9_43", "xinput1_3"] {
            let repair = KnownFixes.dllRepair(for: name)
            #expect(repair.map { ids.contains($0.dependency) } == true)
        }
    }
}
