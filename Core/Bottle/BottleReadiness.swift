import Foundation

/// Whether the bottle is finished, and the last provisioning and dependency
/// outcomes, kept in the shared suite so every face reads one record.
nonisolated enum BottleReadiness {
    struct ProvisionOutcome: Sendable, Equatable {
        let succeeded: Bool
        let reason: String
        let date: Date
        let engine: String
        let bottle: String
        /// Whether the client must stay down, as after a failed Steam install
        /// that left no client to start.
        let blocksClientStart: Bool

        var dictionary: [String: Any] {
            [
                "succeeded": succeeded, "reason": reason,
                "date": ISO8601DateFormatter().string(from: date),
                "engine": engine, "bottle": bottle,
                "blocks_client_start": blocksClientStart,
            ]
        }
    }

    // MARK: - Provisioning

    static func record(provision outcome: ProvisionOutcome) {
        store(stored(outcome), forKey: provisionKey)
    }

    /// The record as the suite holds it, testable without the live suite.
    static func stored(_ outcome: ProvisionOutcome) -> [String: Any] {
        [
            "succeeded": outcome.succeeded,
            "reason": outcome.reason,
            "date": outcome.date.timeIntervalSince1970,
            "engine": outcome.engine,
            "bottle": outcome.bottle,
            "blocksClientStart": outcome.blocksClientStart,
        ]
    }

    static func outcome(from object: [String: Any]?) -> ProvisionOutcome? {
        guard let object,
              let succeeded = object["succeeded"] as? Bool,
              let reason = object["reason"] as? String,
              let seconds = object["date"] as? TimeInterval
        else { return nil }
        return ProvisionOutcome(
            succeeded: succeeded, reason: reason,
            date: Date(timeIntervalSince1970: seconds),
            engine: object["engine"] as? String ?? "",
            bottle: object["bottle"] as? String ?? "",
            blocksClientStart: object["blocksClientStart"] as? Bool ?? false,
        )
    }

    /// The failure holding the client down for this engine and bottle.
    static func block(
        from outcome: ProvisionOutcome?, engine: String, bottle: String,
    ) -> String? {
        guard let outcome, !outcome.succeeded, outcome.blocksClientStart,
              outcome.engine == engine, outcome.bottle == bottle
        else { return nil }
        return outcome.reason
    }

    /// Also clears a block.
    static func recordProvisionSucceeded() {
        record(provision: ProvisionOutcome(
            succeeded: true, reason: "the bottle is complete", date: .now,
            engine: Engine.active.description, bottle: SteamBottle.name,
            blocksClientStart: false,
        ))
    }

    static func recordProvisionFailed(_ reason: String, blocksClientStart: Bool) {
        record(provision: ProvisionOutcome(
            succeeded: false, reason: reason, date: .now,
            engine: Engine.active.description, bottle: SteamBottle.name,
            blocksClientStart: blocksClientStart,
        ))
    }

    static var lastProvision: ProvisionOutcome? {
        outcome(from: Preferences.shared.dictionary(forKey: provisionKey))
    }

    /// The failure holding the client down now, if any.
    static var clientStartBlock: String? {
        block(
            from: lastProvision,
            engine: Engine.active.description, bottle: SteamBottle.name,
        )
    }

    /// Lifts the record's hold on the client, at the user's request.
    static func allowClientStart() {
        guard let outcome = lastProvision else { return }
        record(provision: ProvisionOutcome(
            succeeded: outcome.succeeded, reason: outcome.reason, date: outcome.date,
            engine: outcome.engine, bottle: outcome.bottle, blocksClientStart: false,
        ))
    }

    // MARK: - Dependencies

    /// The last install failure for one catalog entry, until it installs.
    static func dependencyFailure(_ id: String) -> String? {
        guard let failure = dependencyFailures[id] else { return nil }
        guard let dependency = BottleDependencies.catalog.first(where: { $0.id == id }),
              !BottleDependencies.isInstalled(dependency)
        else {
            record(dependency: id, failure: nil)
            return nil
        }
        return failure
    }

    static func record(dependency id: String, failure: String?) {
        var failures = dependencyFailures
        failures[id] = failure
        store(failures, forKey: dependencyKey)
    }

    private static var dependencyFailures: [String: String] {
        Preferences.shared.dictionary(forKey: dependencyKey) as? [String: String] ?? [:]
    }

    /// Every catalog entry's state, for the diagnostics zip and `doctor --json`.
    static func dependencyReport() -> [[String: Any]] {
        BottleDependencies.catalog.map { dependency in
            var entry: [String: Any] = [
                "id": dependency.id,
                "name": dependency.name,
                "required": dependency.required,
                "installed": BottleDependencies.isInstalled(dependency),
            ]
            if let failure = dependencyFailure(dependency.id) { entry["last_failure"] = failure }
            return entry
        }
    }

    /// The sentence for missing required pieces, or `nil`.
    static func incompleteSummary() -> String? {
        incompleteSummary(missing: BottleDependencies.missingRequired().map(\.name))
    }

    /// The same sentence for a list the caller has.
    static func incompleteSummary(missing names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1
            ? String(localized: "\(list) is required and not installed")
            : String(localized: "\(list) are required and not installed")
    }

    // MARK: - Storage

    private static let provisionKey = "lastProvision"
    private static let dependencyKey = "dependencyFailures"

    private static func store(_ value: [String: Any], forKey key: String) {
        Preferences.shared.set(value, forKey: key)
    }
}
