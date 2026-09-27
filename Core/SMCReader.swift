import Foundation
import IOKit

/// A minimal SMC client that reports the CPU's temperature in °C. No private
/// headers and no entitlements. The same reader ships in Adrafinil.
///
/// **The struct layout is load-bearing.** The SMC is driven through
/// `IOConnectCallStructMethod` with an `SMCParamStruct` that must be exactly
/// 80 bytes with C field offsets, or the kernel rejects the call. Swift packs
/// a nested struct's trailing padding into the following field, which makes a
/// 76-byte struct, so the one below is flat with explicit padding, and an
/// `assert` guards its size.
///
/// **Apple Silicon has no single CPU sensor** (Intel's `TC0P`). It exposes
/// dozens of per-core sensors named `Tp…` (performance cores) and `Te…`
/// (efficiency cores) as IEEE floats (`flt `). They are enumerated once and
/// their average is the reading: a package-like number that one core's spike
/// does not move. Intel Macs fall back to `TC0P`/`TC0D` (`sp78`).
final nonisolated class SMCReader: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private var isOpen: Bool {
        connection != 0
    }
    /// CPU temperature sensor keys, discovered once on first read and cached for the connection.
    private var cpuSensorKeys: [String]?

    deinit { close() }

    func open() -> Bool {
        guard !isOpen else { return true }
        assert(MemoryLayout<SMCParamStruct>.size == 80, "SMCParamStruct must be 80 bytes or every SMC call fails")
        let matching = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    func close() {
        if isOpen {
            IOServiceClose(connection)
            connection = 0
        }
    }

    /// Average CPU temperature in °C across the discovered core sensors, or nil if none can be read.
    func readCPUTemperature() -> Double? {
        guard open() else { return nil }
        let keys = cpuSensorKeys ?? discoverCPUSensors()
        guard !keys.isEmpty else { return nil }
        var sum = 0.0
        var n = 0
        for k in keys {
            if let t = readTemperature(key: k), t > 5, t < 120 {
                sum += t
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    /// Reads a four-character SMC key as a Double in °C (handles `sp78` and `flt ` formats).
    func readTemperature(key: String) -> Double? {
        guard open(), key.utf8.count == 4 else { return nil }
        guard let (size, type) = keyInfo(key), let b = readKeyBytes(key, size: size) else { return nil }
        return decodeTemperature(b.0, b.1, b.2, b.3, type: type)
    }

    // MARK: - Sensor discovery

    /// Finds the CPU temperature sensors once. Apple Silicon: every `Tp…`/`Te…` key reporting a
    /// plausible `flt ` temperature. Intel: the first available classic proximity/die key. Cached on
    /// the instance so the (one-time, ~2k-key) enumeration doesn't repeat on every poll.
    private func discoverCPUSensors() -> [String] {
        var keys: [String] = []
        if let count = keyCount() {
            for idx in 0 ..< count {
                guard let name = keyByIndex(idx), name.hasPrefix("Tp") || name.hasPrefix("Te") else { continue }
                guard let (size, type) = keyInfo(name), type == "flt ", let b = readKeyBytes(name, size: size) else { continue }
                if let t = decodeTemperature(b.0, b.1, b.2, b.3, type: type), t > 5, t < 120 {
                    keys.append(name)
                }
            }
        }
        if keys.isEmpty {
            // Intel fallback: classic CPU proximity/die sensors (sp78).
            for k in ["TC0P", "TC0D", "TC0E", "TC0F", "TCXC"] where readTemperature(key: k) != nil {
                keys.append(k)
            }
        }
        // Only a successful discovery is cached: a transient SMC failure that finds
        // no sensors is retried on the next read.
        if !keys.isEmpty { cpuSensorKeys = keys }
        return keys
    }

    /// Total number of SMC keys, read from the synthetic `#KEY` key (a `ui32`).
    private func keyCount() -> UInt32? {
        guard let (size, _) = keyInfo("#KEY"), let b = readKeyBytes("#KEY", size: size) else { return nil }
        return (UInt32(b.0) << 24) | (UInt32(b.1) << 16) | (UInt32(b.2) << 8) | UInt32(b.3)
    }

    /// The key name at a given index, via `kSMCGetKeyFromIndex` — how the full key list is walked.
    private func keyByIndex(_ index: UInt32) -> String? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.data8 = 8 // kSMCGetKeyFromIndex
        input.data32 = index
        guard call(&input, &output) else { return nil }
        return decodeFourCC(output.key)
    }

    // MARK: - low level

    private func keyInfo(_ key: String) -> (size: UInt32, type: String)? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCharCode(from: key)
        input.data8 = 9 // kSMCGetKeyInfo
        guard call(&input, &output) else { return nil }
        return (output.keyInfoDataSize, decodeFourCC(output.keyInfoDataType))
    }

    private func readKeyBytes(_ key: String, size: UInt32) -> (UInt8, UInt8, UInt8, UInt8)? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCharCode(from: key)
        input.keyInfoDataSize = size
        input.data8 = 5 // kSMCReadKey
        guard call(&input, &output) else { return nil }
        return (output.bytes.0, output.bytes.1, output.bytes.2, output.bytes.3)
    }

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> Bool {
        var outputSize = MemoryLayout<SMCParamStruct>.size
        let inputSize = MemoryLayout<SMCParamStruct>.size
        return IOConnectCallStructMethod(connection, 2, &input, inputSize, &output, &outputSize) == kIOReturnSuccess
    }

    private func fourCharCode(from s: String) -> UInt32 {
        let bytes = Array(s.utf8)
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    private func decodeFourCC(_ value: UInt32) -> String {
        let b0 = UInt8((value >> 24) & 0xFF)
        let b1 = UInt8((value >> 16) & 0xFF)
        let b2 = UInt8((value >> 8) & 0xFF)
        let b3 = UInt8(value & 0xFF)
        return String(bytes: [b0, b1, b2, b3], encoding: .ascii) ?? ""
    }

    private func decodeTemperature(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8, type: String) -> Double? {
        // Only the temperature formats matter: "sp78" (Intel fixed-point) and "flt " (Apple Silicon).
        switch type {
        case "sp78":
            // 16-bit signed fixed-point, 8 integer + 8 fraction bits, big-endian.
            let raw = Int16(bitPattern: (UInt16(b0) << 8) | UInt16(b1))
            return Double(raw) / 256.0
        case "flt ":
            // IEEE 754 float, little-endian.
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) {
                $0[0] = b0; $0[1] = b1; $0[2] = b2; $0[3] = b3
            }
            return Double(value)
        default:
            return nil
        }
    }
}

// MARK: - SMCParamStruct

/// The SMC IOKit transport struct. Laid out **flat with explicit padding** to be exactly 80 bytes
/// with the same field offsets as the C `SMCKeyData_t` — nesting the sub-structs lets Swift reuse
/// their trailing padding and shifts `result`/`data32`, producing a 76-byte struct the kernel
/// rejects. Offsets (verified): key@0, vers@4, pLimit@12, keyInfo@28, result@40, data32@44, bytes@48.
private nonisolated struct SMCParamStruct {
    var key: UInt32 = 0
    var versMajor: UInt8 = 0, versMinor: UInt8 = 0, versBuild: UInt8 = 0, versReserved: UInt8 = 0
    var versRelease: UInt16 = 0, versPad: UInt16 = 0
    var pLimitVersion: UInt16 = 0, pLimitLength: UInt16 = 0
    var pLimitCpu: UInt32 = 0, pLimitGpu: UInt32 = 0, pLimitMem: UInt32 = 0
    var keyInfoDataSize: UInt32 = 0, keyInfoDataType: UInt32 = 0
    var keyInfoDataAttributes: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0, pad3: UInt8 = 0
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0, pad4: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    )
}
