import Foundation

/// Whether the bottle is finished, and what is on record about the last
/// attempt to finish it.
///
/// A provisioning pass and a dependency install both fail into a view the
/// user has usually left by the time they read it. Both outcomes are written
/// here instead, in the shared preference suite, so the Engine pane, the
/// popover, `sevo doctor` and the diagnostics zip all read one record — and
/// so a failure survives the navigation that used to erase it.
nonisolated enum BottleReadiness {
    /// What a provisioning pass ended as, and for which pair.
    struct ProvisionOutcome: Sendable, Equatable {
        let succeeded: Bool
        /// The failure in the user's words, or the stage that finished.
        let reason: String
        let date: Date
        let engine: String
        let bottle: String
        /// Whether the client must stay down until this is resolved. A Steam
        /// installer that failed leaves a prefix with no client to start, and
        /// starting one anyway is how a switch ends with the app supervising
        /// a bottle that has no Steam in it.
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

    /// The record as the preference suite holds it, and back. Split from the
    /// storage so both directions can be read — and tested — without a
    /// suite the live app is also reading.
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

    /// The failure in `outcome` that holds the client down for the given
    /// pair, if it is one. A record made for another engine or another
    /// bottle says nothing about this one.
    static func block(
        from outcome: ProvisionOutcome?, engine: String, bottle: String,
    ) -> String? {
        guard let outcome, !outcome.succeeded, outcome.blocksClientStart,
              outcome.engine == engine, outcome.bottle == bottle
        else { return nil }
        return outcome.reason
    }

    /// Records a pass that finished, which is also what clears a block.
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

    /// The failure standing in the way of starting the client, if one is:
    /// the last pass failed at a stage that leaves nothing to start, for the
    /// pair in use, and nobody has retried it or asked for it anyway.
    static var clientStartBlock: String? {
        block(
            from: lastProvision,
            engine: Engine.active.description, bottle: SteamBottle.name,
        )
    }

    /// Starts the client anyway — the user's own decision, taken in the
    /// Engine pane. The record stays; only its hold on the client is lifted.
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

    /// Every catalog entry with what is true of it right now — the shape the
    /// diagnostics zip and `doctor --json` both carry.
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

    /// What to say about the required pieces the bottle lacks, or `nil` when
    /// it lacks none.
    static func incompleteSummary() -> String? {
        incompleteSummary(missing: BottleDependencies.missingRequired().map(\.name))
    }

    /// The same sentence for a list a caller already has — the Settings pane
    /// reads its rows, which a simulated environment can pose.
    static func incompleteSummary(missing names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let list = names.count == 2
            ? names.joined(separator: " and ")
            : names.enumerated().map { index, name in
                index == names.count - 1 && names.count > 1 ? "and \(name)" : name
            }.joined(separator: ", ")
        return names.count == 1
            ? "\(list) is required and not installed"
            : "\(list) are required and not installed"
    }

    // MARK: - Storage

    private static let provisionKey = "lastProvision"
    private static let dependencyKey = "dependencyFailures"

    private static func store(_ value: [String: Any], forKey key: String) {
        Preferences.shared.set(value, forKey: key)
    }
}
