import Foundation

/// What the fix list wrote into one game's own settings at its first launch,
/// and what those settings were before, so that it can be undone key by key.
nonisolated struct AppliedFixes: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        var title: String
        var reason: String
    }

    var fixes: [Source]
    /// The keys the fix list wrote, with the values they were left at.
    var applied: ConfigValues
    /// The game's own values of those keys before; a missing key was unset.
    var previous: ConfigValues
    var date: Date

    /// The keys still holding what the fix list wrote.
    func keys(in own: ConfigValues) -> [String] {
        let current = own.fields
        return applied.fields.filter { FixLedger.same(current[$0.key], $0.value) }.keys.sorted()
    }

    /// Whether `key` still holds what the fix list wrote.
    func sets(_ key: String, in own: ConfigValues) -> Bool {
        keys(in: own).contains(key)
    }

    /// The event log's line for a first launch that took these fixes.
    func logLine(appID: Int, name: String) -> String {
        let titles = fixes.map(\.title).joined(separator: ", ")
        let changes = GameConfig.changes(from: previous, to: applied).joined(separator: ", ")
        return "fixes: \(name) (\(appID)) first launch took \(titles): \(changes)"
    }

    var reasons: String {
        fixes.map { InterfaceCopy.localized($0.reason) }.joined(separator: "\n\n")
    }
}

/// At a game's first launch, every matching fix (``FixList``) sets the keys
/// the game lacks, recorded in ``AppliedFixes`` for Undo. A game is decided
/// once: the record outlives an undo, and a game with an earlier run record is
/// left alone.
nonisolated enum FixLedger {
    static let root = GameConfig.root.appendingPathComponent("fixes")

    // MARK: - The decision

    /// Whether a launch is one the fix list applies to: the switch is on, no
    /// run of the game was ever recorded here, and the game was not decided
    /// before.
    static func isFirstLaunch(enabled: Bool, hasRunRecord: Bool, wasDecided: Bool) -> Bool {
        enabled && !hasRunRecord && !wasDecided
    }

    /// The game's values with each fix's ``FixValues/automatic(_:)`` part
    /// filling what it lacks, and the record; `nil` when nothing changes. The
    /// first fix to name a key wins; a table gains missing entries.
    static func plan(
        own: ConfigValues, fixes: [KnownFix], date: Date = .now,
    ) -> (values: ConfigValues, record: AppliedFixes)? {
        let before = own.fields
        var fields = before
        var written: Set<String> = []
        var sources: [AppliedFixes.Source] = []
        for fix in fixes {
            var contributed = false
            for (key, value) in FixValues.automatic(fix.values).fields {
                switch fields[key] {
                case nil:
                    fields[key] = value
                case let table as [String: Any]:
                    guard let entries = value as? [String: Any] else { continue }
                    let missing = entries.filter { table[$0.key] == nil }
                    guard !missing.isEmpty else { continue }
                    fields[key] = table.merging(missing) { own, _ in own }
                default:
                    continue
                }
                written.insert(key)
                contributed = true
            }
            if contributed { sources.append(AppliedFixes.Source(title: fix.title, reason: fix.reason)) }
        }
        guard !written.isEmpty,
              let values = ConfigValues(fields: fields),
              let applied = ConfigValues(fields: fields.filter { written.contains($0.key) }),
              let previous = ConfigValues(fields: before.filter { written.contains($0.key) })
        else { return nil }
        return (values, AppliedFixes(fixes: sources, applied: applied, previous: previous, date: date))
    }

    /// Puts `keys` (all when `nil`) back and drops them from the record; a key
    /// the player changed keeps the player's value.
    static func undo(
        _ record: AppliedFixes, keys: Set<String>? = nil, own: ConfigValues,
    ) -> (values: ConfigValues, record: AppliedFixes) {
        var fields = own.fields
        var applied = record.applied.fields
        var previous = record.previous.fields
        for key in applied.keys.sorted() where keys?.contains(key) ?? true {
            if same(fields[key], applied[key]) { fields[key] = previous[key] }
            applied[key] = nil
            previous[key] = nil
        }
        var updated = record
        updated.applied = ConfigValues(fields: applied) ?? .empty
        updated.previous = ConfigValues(fields: previous) ?? .empty
        return (ConfigValues(fields: fields) ?? own, updated)
    }

    /// Whether two decoded JSON values are the same value.
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): canonical(a) == canonical(b)
        default: false
        }
    }

    private static func canonical(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    // MARK: - On disk

    static func record(for appID: Int, in root: URL = root) -> AppliedFixes? {
        guard let data = try? Data(contentsOf: url(for: appID, in: root)) else { return nil }
        return try? decoder.decode(AppliedFixes.self, from: data)
    }

    static func save(_ record: AppliedFixes, for appID: Int, in root: URL = root) {
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: url(for: appID, in: root), options: .atomic)
    }

    private static func url(for appID: Int, in root: URL) -> URL {
        root.appendingPathComponent("\(appID).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Applying and undoing

    /// Applies the fix list at a first launch unless `commit` refuses
    /// (``LaunchPreparation/Gate``). The record is written before the values,
    /// so a game is never fixed twice.
    static func applyAtFirstLaunch(appID: Int, committing commit: () -> Bool = { true }) -> AppliedFixes? {
        let own = GameConfig.game(appID)
        return apply(
            appID: appID,
            enabled: Preferences.appliesKnownFixes,
            hasRunRecord: RunLog.hasRecord(forApp: appID),
            own: own,
            fixes: KnownFixes.recommended(for: appID, exes: own.exes ?? []).fixes,
            committing: commit,
        ) { values in
            GameConfig.update(game: appID, bottle: SteamBottle.name, prefix: SteamBottle.root) { $0 = values }
        }
    }

    /// ``applyAtFirstLaunch(appID:committing:)`` with its inputs injected.
    static func apply(
        appID: Int, enabled: Bool, hasRunRecord: Bool, own: ConfigValues, fixes: [KnownFix],
        in root: URL = root, committing commit: () -> Bool, write: (ConfigValues) -> Void,
    ) -> AppliedFixes? {
        guard isFirstLaunch(
            enabled: enabled, hasRunRecord: hasRunRecord, wasDecided: record(for: appID, in: root) != nil,
        ), let planned = plan(own: own, fixes: fixes), commit() else { return nil }
        save(planned.record, for: appID, in: root)
        write(planned.values)
        return planned.record
    }

    /// Undoes `keys` (all when `nil`) for a game; answers the updated record.
    @discardableResult
    static func undo(appID: Int, keys: Set<String>? = nil, inBackground: Bool = false) -> AppliedFixes? {
        guard let record = record(for: appID) else { return nil }
        var updated = record
        GameConfig.update(
            game: appID, bottle: SteamBottle.name, prefix: SteamBottle.root, inBackground: inBackground,
        ) { values in
            let undone = undo(record, keys: keys, own: values)
            values = undone.values
            updated = undone.record
        }
        save(updated, for: appID)
        return updated
    }
}

// MARK: - Values as JSON fields

nonisolated extension ConfigValues {
    /// The values as a JSON object of stored names.
    var fields: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// `nil` when the object does not decode.
    init?(fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
              let values = try? JSONDecoder().decode(ConfigValues.self, from: data)
        else { return nil }
        self = values
    }
}
