import Foundation

/// What the fix list wrote into one game's own settings at its first launch,
/// and what those settings were before, so that it can be undone key by key.
nonisolated struct AppliedFixes: Codable, Equatable, Sendable {
    /// A fix that set something, as the notification and Settings name it.
    struct Source: Codable, Equatable, Sendable {
        var title: String
        var reason: String
    }

    var fixes: [Source]
    /// The keys the fix list wrote, with the values they were left at.
    var applied: ConfigValues
    /// The game's own values of those keys before. A key missing here was
    /// unset; a table (DLL overrides) is the game's own table before the
    /// fix's entries joined it.
    var previous: ConfigValues
    var date: Date

    /// The keys still holding what the fix list wrote, by their
    /// ``ConfigValues`` name. A key the player has changed since is theirs.
    func keys(in own: ConfigValues) -> [String] {
        let current = own.fields
        return applied.fields.filter { FixLedger.same(current[$0.key], $0.value) }.keys.sorted()
    }

    /// Whether `key` still holds what the fix list wrote.
    func sets(_ key: String, in own: ConfigValues) -> Bool {
        keys(in: own).contains(key)
    }

    /// The reasons of the fixes behind it, one paragraph each.
    var reasons: String {
        fixes.map { InterfaceCopy.localized($0.reason) }.joined(separator: "\n\n")
    }
}

/// The first-launch half of the fix list: the first time a game launches
/// under Sevoflurane, every matching fix (``FixList``) sets the keys the
/// game has no value of its own for, and the record of it
/// (``AppliedFixes``) is what Settings' and the notification's Undo read.
///
/// A game is decided once. The record stays after an undo, so a game whose
/// fixes were undone is never fixed again, and a game with a run record from
/// before is left as it is.
nonisolated enum FixLedger {
    static let root = GameConfig.root.appendingPathComponent("fixes")

    // MARK: - The decision

    /// Whether a launch is one the fix list applies to: the switch is on, no
    /// run of the game was ever recorded here, and the game was not decided
    /// before.
    static func isFirstLaunch(enabled: Bool, hasRunRecord: Bool, wasDecided: Bool) -> Bool {
        enabled && !hasRunRecord && !wasDecided
    }

    /// The game's values with every fix's automatic part
    /// (``FixValues/automatic(_:)``) folded in where it has no value of its
    /// own, and the record of what changed; `nil` when the fixes set nothing
    /// the game lacks. The first fix to name a key wins it; a table gains the
    /// entries it does not have.
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

    /// The game's values with `keys` (every key when `nil`) put back as they
    /// were, and the record without them. A key the player changed after the
    /// fix keeps the player's value and leaves the record all the same.
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

    /// Applies the fix list to a game launching for the first time, writing
    /// its values and the engine's env files; `nil` when this launch is not
    /// a first one or no fix sets anything the game lacks. The record is
    /// written before the values, so a game is never fixed twice.
    static func applyAtFirstLaunch(appID: Int) -> AppliedFixes? {
        guard isFirstLaunch(
            enabled: Preferences.appliesKnownFixes,
            hasRunRecord: RunLog.hasRecord(forApp: appID),
            wasDecided: record(for: appID) != nil,
        ) else { return nil }
        let own = GameConfig.game(appID)
        let fixes = KnownFixes.recommended(for: appID, exes: own.exes ?? []).fixes
        guard let planned = plan(own: own, fixes: fixes) else { return nil }
        save(planned.record, for: appID)
        GameConfig.update(game: appID, bottle: SteamBottle.name, prefix: SteamBottle.root) { $0 = planned.values }
        return planned.record
    }

    /// Puts `keys` (every key when `nil`) of a game back as they were before
    /// the fix list, and answers the record as it stands after.
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
    /// The values as their JSON object: one field per key that is set, by
    /// its stored name.
    var fields: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Values from a JSON object of stored names, `nil` where one does not
    /// decode.
    init?(fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
              let values = try? JSONDecoder().decode(ConfigValues.self, from: data)
        else { return nil }
        self = values
    }
}
