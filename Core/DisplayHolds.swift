import Darwin
import Foundation
import IOKit.pwr_mgt

/// Every display-awake power assertion and whose it is. `pmset -g assertions` names a
/// Wine process only `wine`; this reads the same table (`IOPMCopyAssertionsByProcess`)
/// and names our holds, a bottle process's by its Windows program.
nonisolated enum DisplayHolds {
    /// The assertion types that keep a display from sleeping. `UserIsActive` is declared
    /// activity (input, `caffeinate -u`): it restarts the idle clock and times out.
    static let displayTypes: Set<String> = [
        "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion", "UserIsActive",
    ]

    struct Hold: Sendable, Equatable, Codable {
        /// The process the hold was taken on behalf of.
        var pid: pid_t
        var process: String
        var type: String
        var name: String
        var since: Date?
        /// Sevoflurane's own, or a bottle process's.
        var isOurs: Bool
    }

    /// The display holds right now.
    static func current(ownRoots: [String] = defaultOwnRoots) -> [Hold] {
        var table: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&table) == kIOReturnSuccess,
              let byProcess = table?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        return byProcess.values.flatMap(\.self).compactMap { hold(from: $0, ownRoots: ownRoots) }
            .sorted { ($0.since ?? .distantPast) < ($1.since ?? .distantPast) }
    }

    /// Nil when the assertion does not hold the display.
    static func hold(from entry: [String: Any], ownRoots: [String]) -> Hold? {
        guard let type = entry["AssertType"] as? String, displayTypes.contains(type) else { return nil }
        let owner = (entry["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
            ?? (entry["AssertPID"] as? NSNumber)?.int32Value ?? 0
        let executable = WineOrphans.executablePath(of: owner) ?? ""
        let isOurs = owner == getpid() || ownRoots.contains { !$0.isEmpty && executable.hasPrefix($0) }
        let windowsProgram = isOurs ? WineOrphans.commandLine(of: owner)
            .flatMap { $0.hasPrefix("C:\\") ? $0.split(separator: "\\").last.map(String.init) : nil } : nil
        return Hold(
            pid: owner,
            process: windowsProgram ?? (entry["Process Name"] as? String) ?? (executable as NSString).lastPathComponent,
            type: type,
            name: entry["AssertName"] as? String ?? "",
            since: startDate(entry["AssertStartWhen"]),
            isOurs: isOurs,
        )
    }

    /// Sevoflurane's app, its helper and every engine.
    static let defaultOwnRoots = [
        AppIdentity.supportFolder.path,
        "/Applications/Sevoflurane.app",
        Bundle.main.bundlePath,
    ]

    private static func startDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let text = value as? String else { return nil }
        return stamp.date(from: text)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// One line per hold: `steam.exe · UserIsActive · Wine user input · 42 min`.
    static func describe(_ hold: Hold, now: Date = .now) -> String {
        let age = hold.since.map { " · \(Int(now.timeIntervalSince($0) / 60)) min" } ?? ""
        return "\(hold.process) (pid \(hold.pid)) · \(hold.type) · \(hold.name)\(age)"
    }
}

/// Logs each of our display holds that outlives every game run by ``grace``, once.
nonisolated struct DisplayHoldWatch: Sendable {
    static let grace: TimeInterval = 5 * 60

    private var reported: Set<String> = []

    init() {}

    /// Ours, older than ``grace``, with no run open, not reported before; a run
    /// opening resets what was reported.
    mutating func check(_ holds: [DisplayHolds.Hold], runOpen: Bool, now: Date = .now) -> [DisplayHolds.Hold] {
        guard !runOpen else {
            reported.removeAll()
            return []
        }
        let stale = holds.filter { hold in
            hold.isOurs && (hold.since.map { now.timeIntervalSince($0) >= Self.grace } ?? false)
        }
        let fresh = stale.filter { !reported.contains(key(of: $0)) }
        reported = Set(stale.map(key(of:)))
        return fresh
    }

    private func key(of hold: DisplayHolds.Hold) -> String {
        "\(hold.pid) \(hold.type) \(hold.name)"
    }
}
