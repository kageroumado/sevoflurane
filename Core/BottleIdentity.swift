import Darwin
import Foundation

/// One bottle a stop can aim at: the prefix and the engine whose wineserver
/// runs it, so `wineserver -k` and the `-shutdown` fallback reach the server
/// that actually holds the prefix.
nonisolated struct BottleTarget: Equatable, Sendable {
    let prefix: URL
    let engine: Engine
    /// The prefix as the kernel reports it, links resolved: what two targets
    /// are compared by, and what a process's working directory is matched to.
    let path: String

    init(prefix: URL, engine: Engine) {
        self.prefix = prefix
        self.engine = engine
        path = prefix.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The bottle's folder name, which is how the log and the CLI name it.
    var name: String {
        prefix.lastPathComponent
    }

    static func == (lhs: BottleTarget, rhs: BottleTarget) -> Bool {
        lhs.path == rhs.path
    }

    /// The bottle the preference names now, under the engine this process
    /// resolved.
    static var configured: BottleTarget {
        BottleTarget(prefix: SteamBottle.root, engine: Engine.active)
    }

    /// What every scoped lookup and stop reaches: the bottle the client
    /// booted in and the configured one. They differ when the preference
    /// moved under a running client, and a stop aimed at the preference alone
    /// finds nothing and leaves that client running.
    static var inScope: [BottleTarget] {
        stopSet(booted: BootedBottle.target, configured: configured)
    }

    /// The booted bottle, the configured one and any strays, each once, in
    /// that order. The booted bottle leads because its engine is the one whose
    /// wineserver holds the prefix when the two share a path.
    static func stopSet(
        booted: BottleTarget?, configured: BottleTarget, strays: [BottleTarget] = [],
    ) -> [BottleTarget] {
        var set: [BottleTarget] = []
        for target in [booted].compactMap(\.self) + [configured] + strays where !set.contains(target) {
            set.append(target)
        }
        return set
    }

    /// How a stop names its reach: the configured bottle alone, or every
    /// bottle it reaches with the configured one said.
    static func scopeNote(_ targets: [BottleTarget], configured: BottleTarget) -> String {
        guard targets != [configured] else { return "bottle \(configured.name)" }
        return "bottles \(targets.map(\.name).joined(separator: ", ")) (configured: \(configured.name))"
    }
}

/// The bottle the running client was launched in.
///
/// Written only when the client is spawned. The graphics record beside it is
/// also rewritten by a hot restage, which moves no client, so the bottle keeps
/// a key of its own.
nonisolated enum BootedBottle {
    private static let key = "bootedBottle"

    static func record(_ target: BottleTarget) {
        Preferences.shared.set(
            ["prefix": target.prefix.path, "engine": target.engine.root.path],
            forKey: key,
        )
    }

    static var target: BottleTarget? {
        guard let stored = Preferences.shared.dictionary(forKey: key),
              let prefix = stored["prefix"] as? String, !prefix.isEmpty
        else { return nil }
        let engine = (stored["engine"] as? String).flatMap(Engine.booted(fromRoot:)) ?? Engine.active
        return BottleTarget(prefix: URL(fileURLWithPath: prefix), engine: engine)
    }
}

/// Which bottle the client answering on the CDP port lives in, and which
/// Sevoflurane bottles have a wineserver running.
///
/// At most one bottle's client runs, and it is the configured one. A client
/// found in another Sevoflurane bottle is foreign, and a Sevoflurane bottle
/// with a live wineserver beside the configured one is extra; both are
/// stopped. **Only folders under ``Engine/managedBottlesRoot`` count.** A
/// Wine prefix anywhere else runs on the same engines — a tester's own
/// prefix for another game — and is never stopped, whatever it runs.
nonisolated enum BottleIdentity {
    /// A live wineserver of a managed engine.
    struct Server: Equatable, Sendable {
        /// Its working directory, `/tmp/.wine-<uid>/server-<dev>-<ino>`.
        let serverDirectory: String
        /// The managed engine it runs out of.
        let engineVersion: String?
    }

    /// A Sevoflurane bottle that is running and is not the configured one.
    struct Stray: Equatable, Sendable {
        let prefix: String
        let engineVersion: String?

        var name: String {
            (prefix as NSString).lastPathComponent
        }

        /// The stop's target: the engine whose server holds the prefix, or
        /// the active one when that server was not found.
        var target: BottleTarget {
            BottleTarget(
                prefix: URL(fileURLWithPath: prefix),
                engine: engineVersion.map { .managed(version: $0) } ?? Engine.active,
            )
        }
    }

    struct Verdict: Equatable, Sendable {
        /// The client answering CDP runs in another Sevoflurane bottle.
        var foreignClient: Stray?
        /// Sevoflurane bottles other than the configured one, and other than
        /// a foreign client's, with a live wineserver.
        var extras: [Stray] = []
        /// The client answering CDP runs in a prefix outside Sevoflurane's
        /// bottles. It is neither adopted nor stopped.
        var outsideClient: String?

        var isOurs: Bool {
            foreignClient == nil && extras.isEmpty && outsideClient == nil
        }

        /// Every bottle the verdict stops, the foreign client's first.
        var strays: [Stray] {
            [foreignClient].compactMap(\.self) + extras
        }
    }

    /// Classifies what runs against the configured bottle.
    ///
    /// - Parameters:
    ///   - clientPrefix: the prefix of the process listening on the CDP port,
    ///     or nil when nothing listens or its prefix could not be named.
    ///   - servers: the live wineservers of managed engines.
    ///   - bottles: each folder under Sevoflurane's bottles root, keyed by its
    ///     server directory. Nothing outside it is ever a stray.
    ///   - configured: the configured bottle's path.
    static func classify(
        clientPrefix: String?, servers: [Server], bottles: [String: String], configured: String,
    ) -> Verdict {
        let managed = Set(bottles.values)
        let engines = Dictionary(
            servers.compactMap { server in bottles[server.serverDirectory].map { ($0, server.engineVersion) } },
            uniquingKeysWith: { first, _ in first },
        )
        var verdict = Verdict()
        if let clientPrefix, clientPrefix != configured {
            if managed.contains(clientPrefix) {
                verdict.foreignClient = Stray(prefix: clientPrefix, engineVersion: engines[clientPrefix] ?? nil)
            } else {
                verdict.outsideClient = clientPrefix
            }
        }
        let running = Set(servers.compactMap { bottles[$0.serverDirectory] })
        verdict.extras = running
            .subtracting([configured, verdict.foreignClient?.prefix].compactMap(\.self))
            .sorted()
            .map { Stray(prefix: $0, engineVersion: engines[$0] ?? nil) }
        return verdict
    }

    /// Whether the preference names another bottle than the one the running
    /// client booted in. No record says nothing moved.
    static func bottleMoved(booted: String?, configured: String) -> Bool {
        guard let booted else { return false }
        return booted != configured
    }

    /// What the running Windows was booted with, as far as a restart cares:
    /// the engine, the sync primitives and the bottle.
    struct Boot: Equatable, Sendable {
        var engineRoot: String?
        var msync: Bool?
        var bottle: String?
    }

    /// Whether a restart can stop only Steam and keep the booted Windows.
    /// Anything unknown about the boot takes Windows down, because keeping a
    /// server of another engine, other primitives or another prefix is the
    /// failure and a fresh boot only costs time.
    static func windowsCanStay(booted: Boot, current: Boot) -> Bool {
        booted.engineRoot != nil && booted.engineRoot == current.engineRoot
            && booted.msync != nil && booted.msync == current.msync
            && booted.bottle != nil && booted.bottle == current.bottle
    }

    /// The bottle words `sevo status` prints: the bottle the client runs in,
    /// and the configured one beside it when the two differ.
    static func statusText(clientBottle: String?, configured: String, steamInstalled: Bool) -> String {
        let steam = steamInstalled ? "steam ok" : "no steam"
        guard let clientBottle, clientBottle != configured else {
            return "bottle \(configured) (\(steam))"
        }
        return "client bottle \(clientBottle) · configured bottle \(configured) (\(steam))"
    }

    // MARK: - Paths

    /// A server directory as ``WineOrphans/serverDirectory(forPrefix:uid:)``
    /// spells it. The kernel reports the working directory through the link
    /// `/tmp` is, as `/private/tmp/…`.
    static func canonicalServerDirectory(_ path: String) -> String {
        path.hasPrefix("/private/tmp/") ? String(path.dropFirst("/private".count)) : path
    }

    /// The managed engine a binary belongs to: the first component under the
    /// engines root.
    static func engineVersion(ofExecutable path: String, under root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
    }

    /// The pids `lsof -Fp` lists, one `p<pid>` line each.
    static func listenerPIDs(inLsofFields output: String) -> [pid_t] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            line.first == "p" ? pid_t(line.dropFirst()) : nil
        }
    }

    // MARK: - Looking

    /// Looks at the machine and classifies it against `configured`.
    static func verify(configured: BottleTarget) async -> Verdict {
        let bottles = managedBottles()
        var known = bottles
        if let directory = WineOrphans.serverDirectory(forPrefix: configured.path) {
            known[directory] = configured.path
        }
        return await classify(
            clientPrefix: clientPrefix(known: known),
            servers: liveServers(),
            bottles: bottles,
            configured: configured.path,
        )
    }

    /// The bottle the client answering CDP runs in, by name: what the port
    /// shows when it can be named, and the launch record otherwise.
    static func clientBottleName() async -> String? {
        var known = managedBottles()
        for target in BottleTarget.inScope {
            if let directory = WineOrphans.serverDirectory(forPrefix: target.path) {
                known[directory] = target.path
            }
        }
        if let prefix = await clientPrefix(known: known) {
            return (prefix as NSString).lastPathComponent
        }
        return BootedBottle.target?.name
    }

    /// The prefix of the process listening on the CDP port. The client's
    /// webhelper works inside its prefix; the wineserver, which holds the
    /// socket too, works in its server directory, named through `known`.
    static func clientPrefix(known: [String: String]) async -> String? {
        let out = await Subprocess.run(
            "/usr/sbin/lsof", ["-nP", "-iTCP:\(BridgePorts.cdp)", "-sTCP:LISTEN", "-Fp"],
            timeout: .seconds(10),
        ).output
        for pid in listenerPIDs(inLsofFields: out) {
            guard let directory = WineOrphans.workingDirectory(of: pid) else { continue }
            let canonical = canonicalServerDirectory(directory)
            if let prefix = known[canonical] { return prefix }
            if canonical.hasPrefix("/tmp/.wine-") { continue }
            if let prefix = WineOrphans.prefix(containing: directory) { return prefix }
        }
        return nil
    }

    /// Each folder under Sevoflurane's bottles root, keyed by the directory
    /// its wineserver works in.
    static func managedBottles(root: URL = Engine.managedBottlesRoot) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var bottles: [String: String] = [:]
        for name in names where !name.hasPrefix(".") {
            let path = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let directory = WineOrphans.serverDirectory(forPrefix: path)
            else { continue }
            bottles[directory] = path
        }
        return bottles
    }

    /// Every running wineserver whose binary lies under the managed engines.
    static func liveServers(engines: URL = Engine.managedRoot) -> [Server] {
        let root = engines.resolvingSymlinksInPath().path
        return WineOrphans.allProcessIDs().compactMap { pid in
            guard let executable = WineOrphans.executablePath(of: pid),
                  executable.hasSuffix("/wineserver"),
                  let version = engineVersion(ofExecutable: executable, under: root),
                  let directory = WineOrphans.workingDirectory(of: pid)
            else { return nil }
            return Server(serverDirectory: canonicalServerDirectory(directory), engineVersion: version)
        }
    }
}
