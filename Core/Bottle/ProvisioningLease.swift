import Darwin
import Foundation

/// Setup's hold on the bottle it is provisioning: no client starts there
/// while it lasts, because `Steam.exe` lands minutes before the headless
/// update finishes. A lease lapses when its owner process dies or stops
/// renewing.
nonisolated enum ProvisioningLease {
    struct Lease: Equatable, Sendable {
        /// The standardized prefix, links unresolved because the folder may
        /// not exist yet.
        let prefix: String
        let owner: Int32
        let expires: Date

        var name: String {
            (prefix as NSString).lastPathComponent
        }
    }

    /// How long a lease stands without renewal.
    static let term: TimeInterval = 90
    /// How often a running pass renews it.
    static let renewal: Duration = .seconds(25)

    /// The unexpired lease on `prefix` whose owner is alive, if any.
    static func holding(
        _ lease: Lease?, prefix: String, now: Date, ownerAlive: (Int32) -> Bool,
    ) -> Lease? {
        guard let lease, lease.prefix == prefix, now < lease.expires, ownerAlive(lease.owner)
        else { return nil }
        return lease
    }

    /// The lease on the bottle the preference names now, if one stands.
    static var onConfiguredBottle: Lease? {
        holding(
            stored, prefix: key(for: SteamBottle.root), now: .now, ownerAlive: processIsAlive,
        )
    }

    /// Takes the lease on `prefix` for this process, or renews it.
    static func take(_ prefix: URL) {
        let lease = Lease(prefix: key(for: prefix), owner: getpid(), expires: .now + term)
        Preferences.shared.set(stored(lease), forKey: storageKey)
    }

    /// Gives the lease up, if this process holds it on `prefix`.
    static func release(_ prefix: URL) {
        guard let lease = stored, lease.owner == getpid(), lease.prefix == key(for: prefix)
        else { return }
        Preferences.shared.removeObject(forKey: storageKey)
    }

    /// The lease as the preference suite holds it, and back.
    static func stored(_ lease: Lease) -> [String: Any] {
        ["prefix": lease.prefix, "owner": Int(lease.owner), "expires": lease.expires.timeIntervalSince1970]
    }

    static func lease(from object: [String: Any]?) -> Lease? {
        guard let object,
              let prefix = object["prefix"] as? String,
              let owner = object["owner"] as? Int,
              let expires = object["expires"] as? TimeInterval
        else { return nil }
        return Lease(prefix: prefix, owner: Int32(owner), expires: Date(timeIntervalSince1970: expires))
    }

    static func key(for prefix: URL) -> String {
        prefix.standardizedFileURL.path
    }

    private static var stored: Lease? {
        lease(from: Preferences.shared.dictionary(forKey: storageKey))
    }

    /// `kill(pid, 0)`: EPERM is a live process of another user.
    private static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private static let storageKey = "provisioningLease"
}
