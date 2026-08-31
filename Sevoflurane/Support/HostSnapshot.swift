import Foundation

/// The machine's state at one instant, recorded with every scenario so a
/// timing can be read against the load it was taken under. A number from a
/// host at load average 40 is a fact about the host, not the app.
nonisolated struct HostSnapshot: Encodable, Sendable {
    let loadAverage1m: Double
    let activeProcessors: Int
    let thermalState: String
    let freeMemoryMB: Int
    let compressedMemoryMB: Int
    let physicalMemoryMB: Int

    nonisolated static func take() -> HostSnapshot {
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        let info = ProcessInfo.processInfo
        let vm = vmStatistics()
        let page = Int(sysconf(_SC_PAGESIZE))
        return HostSnapshot(
            loadAverage1m: (loads[0] * 100).rounded() / 100,
            activeProcessors: info.activeProcessorCount,
            thermalState: Self.describe(info.thermalState),
            freeMemoryMB: (Int(vm.free_count) * page) >> 20,
            compressedMemoryMB: (Int(vm.compressor_page_count) * page) >> 20,
            physicalMemoryMB: Int(info.physicalMemory >> 20),
        )
    }

    private nonisolated static func vmStatistics() -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size,
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : vm_statistics64()
    }

    private nonisolated static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
