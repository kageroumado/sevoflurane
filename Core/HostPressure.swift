import Darwin
import Foundation

/// What else is weighing on this Mac while Steam and a game run on it: a
/// launch that crawls under someone else's build is a fact about the Mac, and
/// both the person and the supervisor should read it that way.
nonisolated struct HostPressure: Codable, Equatable, Sendable {
    /// The part of the whole processor in use by everything outside the
    /// bottle and this app, 0 to 1.
    var otherProcessorShare = 0.0
    /// The outside process using the most of it, when one stands out.
    var busiestProcess: String?
    /// The kernel's memory pressure level.
    var memory = MemoryLevel.normal
    /// The CPU's temperature in °C, averaged over its core sensors.
    var temperature: Double?
    /// Whether macOS reports it is slowing the machine down to cool it.
    var isThrottling = false
    var isLowPowerMode = false

    enum MemoryLevel: String, Codable, Sendable {
        case normal
        case warning
        case critical
    }

    /// The levels below which nothing is said or done.
    enum Threshold {
        /// Half the processor gone to other work leaves a game and the
        /// client's forty processes competing for the rest.
        static let busyShare = 0.5
        static let veryBusyShare = 0.8
        /// Apple silicon runs a game in the 80s; the 90s mean the fans have
        /// lost and clocks are next.
        static let hotCelsius = 95.0
        /// A process is named when it alone takes this much of the machine.
        static let namedShare = 0.2
    }

    var isBusy: Bool { otherProcessorShare >= Threshold.busyShare }
    var isHot: Bool { isThrottling || (temperature ?? 0) >= Threshold.hotCelsius }
    var isShortOfMemory: Bool { memory != .normal }

    /// Whether any of it is worth a word.
    var isElevated: Bool { isBusy || isHot || isShortOfMemory || isLowPowerMode }

    /// How much longer the supervisor waits before it calls slowness a fault.
    var patience: Double {
        var factor = 1.0
        if isBusy { factor = otherProcessorShare >= Threshold.veryBusyShare ? 3 : 2 }
        if memory == .critical { factor = max(factor, 3) }
        if isHot || memory == .warning || isLowPowerMode { factor = max(factor, 2) }
        return factor
    }

    /// How loaded the Mac is on a scale of 0 to 1, for a gauge: the busiest
    /// of its signals.
    var level: Double {
        var level = otherProcessorShare
        if let temperature { level = max(level, (temperature - 50) / 50) }
        switch memory {
        case .critical: level = max(level, 1)
        case .warning: level = max(level, 0.75)
        case .normal: break
        }
        if isThrottling { level = max(level, 0.9) }
        return min(1, max(0, level))
    }

    /// The causes, each as a clause, most telling first.
    var causes: [String] {
        var causes: [String] = []
        if isBusy {
            let load = "\(Int((otherProcessorShare * 100).rounded()))%"
            causes.append(busiestProcess.map { String(localized: "other apps have the CPU at \(load), mostly \($0)") }
                ?? String(localized: "other apps have the CPU at \(load)"))
        }
        switch memory {
        case .critical: causes.append(InterfaceCopy.localized("memory is critically short"))
        case .warning: causes.append(InterfaceCopy.localized("memory is running short"))
        case .normal: break
        }
        if isHot {
            let degrees = temperature.map { " (\(Int($0.rounded())) °C)" } ?? ""
            causes.append(isThrottling
                ? String(localized: "the Mac is hot\(degrees) and macOS is slowing it down")
                : String(localized: "the Mac is hot\(degrees)"))
        }
        if isLowPowerMode { causes.append(InterfaceCopy.localized("Low Power Mode is on")) }
        return causes
    }

    /// One sentence for the popover and the log, or `nil` at ordinary levels.
    var sentence: String? {
        guard let first = causes.first else { return nil }
        let isChinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        let text = ([first] + causes.dropFirst()).joined(separator: isChinese ? "；" : "; ")
        return text.prefix(1).uppercased() + text.dropFirst() + (isChinese ? "。" : ".")
    }

    /// The reading with its numbers rounded to what a change of wording
    /// needs, so two readings that say the same thing compare equal.
    var rounded: HostPressure {
        var copy = self
        copy.otherProcessorShare = (otherProcessorShare * 20).rounded() / 20
        copy.temperature = temperature.map { ($0 / 5).rounded() * 5 }
        return copy
    }
}

/// Takes ``HostPressure`` readings. One reading needs the one before it: a
/// processor share is a difference of two tick counts.
final nonisolated class HostPressureSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let smc = SMCReader()
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastProcessTimes: [pid_t: UInt64] = [:]
    private var lastSampleAt = ContinuousClock.now
    private var smoothedShare: Double?
    /// The weight of the newest reading in the smoothed share.
    private static let smoothing = 0.4
    private var names: [pid_t: (name: String, isOurs: Bool)] = [:]
    /// Folders whose processes are the bottle's own.
    private let ownRoots: [String]

    init(ownRoots: [String] = HostPressureSampler.defaultOwnRoots) {
        self.ownRoots = ownRoots
    }

    /// Everything the app keeps in Application Support — engines, a game's
    /// Dock launcher bundle, the NW.js runtimes and their wrapper bundles —
    /// both CrossOver apps, and the app itself.
    static var defaultOwnRoots: [String] {
        // The daemon's bundle is a folder inside the app's; the app is ours
        // whichever of the two asks.
        var app = Bundle.main.bundleURL
        while app.pathComponents.count > 1, app.pathExtension != "app" { app.deleteLastPathComponent() }
        return [
            Engine.managedRoot.deletingLastPathComponent().path,
            "/Applications/CrossOver.app",
            "/Applications/CrossOver Preview.app",
            app.pathExtension == "app" ? app.path : Bundle.main.bundleURL.path,
        ]
    }

    /// Whether the executable at `path` lies inside one of `roots`, taken as
    /// whole directories.
    static func isOurs(path: String, roots: [String]) -> Bool {
        roots.contains { root in
            guard !root.isEmpty else { return false }
            let directory = root.hasSuffix("/") ? String(root.dropLast()) : root
            return path == directory || path.hasPrefix(directory + "/")
        }
    }

    func sample() -> HostPressure {
        lock.withLock {
            var pressure = HostPressure()
            let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
            let now = ContinuousClock.now
            let seconds = Double((now - lastSampleAt).components.attoseconds) / 1e18
                + Double((now - lastSampleAt).components.seconds)
            lastSampleAt = now

            let ticks = Self.processorTicks()
            let processes = processTimes()
            if let ticks, let last = lastTicks, ticks.total > last.total, seconds > 0.5 {
                let total = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
                var ours = 0.0
                // By name: a build is forty compilers, none of which stands
                // out and all of which are the answer.
                var byName: [String: Double] = [:]
                for (pid, time) in processes {
                    guard let before = lastProcessTimes[pid], time >= before, let identity = names[pid] else { continue }
                    let share = Double(time - before) / 1e9 / seconds / cores
                    if identity.isOurs {
                        ours += share
                    } else {
                        byName[identity.name, default: 0] += share
                    }
                }
                let other = min(1, max(0, total - ours))
                // Smoothed over a few readings: one compile step or one
                // Spotlight burst is no state of the machine.
                smoothedShare = smoothedShare.map { $0 * (1 - Self.smoothing) + other * Self.smoothing } ?? other
                pressure.otherProcessorShare = smoothedShare ?? other
                if let busiest = byName.max(by: { $0.value < $1.value }),
                   busiest.value >= HostPressure.Threshold.namedShare {
                    pressure.busiestProcess = busiest.key
                }
            }
            lastTicks = ticks
            lastProcessTimes = processes
            names = names.filter { processes[$0.key] != nil }

            pressure.memory = Self.memoryLevel()
            pressure.temperature = smc.readCPUTemperature()
            pressure.isThrottling = ProcessInfo.processInfo.thermalState.rawValue
                >= ProcessInfo.ThermalState.serious.rawValue
            pressure.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            return pressure
        }
    }

    /// CPU time of every process this user can read, and the identity of any
    /// seen for the first time.
    private func processTimes() -> [pid_t: UInt64] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [:] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var times: [pid_t: UInt64] = [:]
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard let usage = ProcessUsage.read(pid: pid) else { continue }
            times[pid] = usage.cpuTimeNanoseconds
            if names[pid] == nil { names[pid] = identity(of: pid) }
        }
        return times
    }

    private func identity(of pid: pid_t) -> (name: String, isOurs: Bool) {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        let name = path.isEmpty ? "pid \(pid)" : (path as NSString).lastPathComponent
        return (name, Self.isOurs(path: path, roots: ownRoots))
    }

    /// Busy and total ticks of every core together.
    private static func processorTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    private static func memoryLevel() -> HostPressure.MemoryLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return switch level {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }
}
