import CoreAudio
import Foundation

/// The machine's state at one instant, recorded with every scenario so a
/// timing can be read against the load it was taken under.
nonisolated struct HostSnapshot: Encodable, Sendable {
    let loadAverage1m: Double
    let activeProcessors: Int
    let thermalState: String
    let freeMemoryMB: Int
    let compressedMemoryMB: Int
    let physicalMemoryMB: Int
    /// Where sound goes, or `nil` on a Mac with no output device at all.
    let audioOutput: AudioOutput?

    /// The system output device, which Wine's CoreAudio driver opens a game's
    /// audio against.
    struct AudioOutput: Encodable, Sendable, Equatable {
        let name: String
        /// How the device is attached, as ``HostSnapshot/transportWord(_:)``
        /// spells it.
        let transport: String
        let sampleRateHz: Double
        /// Whether any process has the device's I/O running.
        let running: Bool

        /// One line for a log: `MOONDROP Dawn Pro (USB, 96 kHz, running)`.
        var summary: String {
            let rate = String(format: "%g", sampleRateHz / 1000)
            return "\(name) (\(transport), \(rate) kHz, \(running ? "running" : "idle"))"
        }
    }

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
            audioOutput: defaultAudioOutput(),
        )
    }

    /// The system's default output device, or `nil` when the HAL has none.
    nonisolated static func defaultAudioOutput() -> AudioOutput? {
        guard let device: AudioDeviceID = property(
            kAudioHardwarePropertyDefaultOutputDevice, of: AudioObjectID(kAudioObjectSystemObject),
        ), device != kAudioObjectUnknown else { return nil }
        let name: CFString? = property(kAudioObjectPropertyName, of: device)
        let transport: UInt32 = property(kAudioDevicePropertyTransportType, of: device) ?? 0
        let sampleRate: Float64 = property(kAudioDevicePropertyNominalSampleRate, of: device) ?? 0
        let running: UInt32 = property(kAudioDevicePropertyDeviceIsRunningSomewhere, of: device) ?? 0
        return AudioOutput(
            name: reportName(name.map { $0 as String }, transport: transportWord(transport)),
            transport: transportWord(transport),
            sampleRateHz: sampleRate,
            running: running != 0,
        )
    }

    /// A device's name as a log and a report carry it. Headphones and
    /// speakers reached over the air are named after their owner ("Ana's
    /// AirPods Pro"), so those are known by how they are attached; a wired
    /// or built-in device keeps its model name.
    nonisolated static func reportName(_ name: String?, transport: String) -> String {
        let overTheAir = ["bluetooth", "airplay"].contains { transport.lowercased().contains($0) }
        guard !overTheAir else { return "\(transport) device" }
        return name ?? "unnamed device"
    }

    /// A transport type as a word for a log; Bluetooth and Bluetooth LE share one.
    nonisolated static func transportWord(_ code: UInt32) -> String {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        default: "other"
        }
    }

    /// One global-scope property of an audio object, or `nil` when the HAL
    /// declines or answers with a different size.
    private nonisolated static func property<Value>(
        _ selector: AudioObjectPropertySelector, of object: AudioObjectID,
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { value.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
        guard status == noErr, size == UInt32(MemoryLayout<Value>.size) else { return nil }
        return value.move()
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
