import Darwin
import Foundation

/// One bottle a stop can aim at: the prefix and the engine whose wineserver
/// holds it.
nonisolated struct BottleTarget: Equatable, Sendable {
    let prefix: URL
    let engine: Engine
    /// The link-resolved prefix that targets are compared and matched by.
    let path: String

    init(prefix: URL, engine: Engine) {
        self.prefix = prefix
        self.engine = engine
        path = prefix.resolvingSymlinksInPath().standardizedFileURL.path
    }

    var name: String {
        prefix.lastPathComponent
    }

    static func == (lhs: BottleTarget, rhs: BottleTarget) -> Bool {
        lhs.path == rhs.path
    }

    static var configured: BottleTarget {
        BottleTarget(prefix: SteamBottle.root, engine: Engine.active)
    }

    /// What every scoped lookup and stop reaches: the bottle the client
    /// booted in and the configured one. They differ when the preference
    /// moved under a running client, which a stop aimed at the preference
    /// alone would leave running.
    static var inScope: [BottleTarget] {
        stopSet(booted: BootedBottle.target, configured: configured)
    }

    /// The booted bottle, the configured one and any strays, each once; the
    /// booted one leads because its engine holds a shared prefix.
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

/// The bottle the running client was launched in, written only at spawn; a
/// hot restage rewrites the graphics record, so this has its own key.
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
/// Only the configured bottle may run; a client in another Sevoflurane
/// bottle is foreign and another bottle's live wineserver is extra, and both
/// are stopped. **Only folders under ``Engine/managedBottlesRoot`` count**: a
/// prefix anywhere else is never stopped.
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

        /// The engine whose server holds the prefix, else the active one.
        var target: BottleTarget {
            BottleTarget(
                prefix: URL(fileURLWithPath: prefix),
                engine: engineVersion.map { .managed(version: $0) } ?? Engine.active,
            )
        }
    }

    struct Verdict: Equatable, Sendable {
        var foreignClient: Stray?
        /// Other Sevoflurane bottles with a live wineserver.
        var extras: [Stray] = []
        /// A CDP client in a prefix outside Sevoflurane's bottles, which is
        /// left alone.
        var outsideClient: String?

        var isOurs: Bool {
            foreignClient == nil && extras.isEmpty && outsideClient == nil
        }

        var strays: [Stray] {
            [foreignClient].compactMap(\.self) + extras
        }
    }

    /// Classifies what runs against the configured bottle. `bottles` maps
    /// server directories to the folders under the bottles root.
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

    /// Whether the preference moved off the booted bottle; no record is no.
    static func bottleMoved(booted: String?, configured: String) -> Bool {
        guard let booted else { return false }
        return booted != configured
    }

    /// What the running Windows was booted with, as a restart cares.
    struct Boot: Equatable, Sendable {
        var engineRoot: String?
        var msync: Bool?
        var bottle: String?
    }

    /// Whether a restart can keep the booted Windows; anything unknown takes
    /// it down, since a fresh boot only costs time.
    static func windowsCanStay(booted: Boot, current: Boot) -> Bool {
        booted.engineRoot != nil && booted.engineRoot == current.engineRoot
            && booted.msync != nil && booted.msync == current.msync
            && booted.bottle != nil && booted.bottle == current.bottle
    }

    /// The bottle words `sevo status` prints.
    static func statusText(clientBottle: String?, configured: String, steamInstalled: Bool) -> String {
        let steam = steamInstalled ? "steam ok" : "no steam"
        guard let clientBottle, clientBottle != configured else {
            return "bottle \(configured) (\(steam))"
        }
        return "client bottle \(clientBottle) · configured bottle \(configured) (\(steam))"
    }

    // MARK: - Paths

    /// A kernel-reported `/private/tmp/…` server directory as
    /// ``WineOrphans/serverDirectory(forPrefix:uid:)`` spells it.
    static func canonicalServerDirectory(_ path: String) -> String {
        path.hasPrefix("/private/tmp/") ? String(path.dropFirst("/private".count)) : path
    }

    /// The first component of `path` under the engines root.
    static func engineVersion(ofExecutable path: String, under root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
    }

    /// Whether a process's command line says it serves the CDP port: the
    /// client is launched with `-devtools-port <port>` and spawns its
    /// webhelper with `--remote-debugging-port=<port>`, so the port is in
    /// the arguments of both. Never ask `lsof` instead: it walks every mount
    /// and blocks for good on a wedged one (a stuck DeviceFS held thirty of
    /// them, and the supervisor with them, in an uninterruptible wait).
    static func servesCDPPort(commandLine: String, port: Int = BridgePorts.cdp) -> Bool {
        let arguments = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        if arguments.contains("--remote-debugging-port=\(port)") { return true }
        return zip(arguments, arguments.dropFirst()).contains { flag, value in
            flag == "-devtools-port" && value == "\(port)"
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

    /// The name of the bottle the CDP client runs in, else the launch record's.
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

    /// The prefix of the process serving the CDP port: the webhelper's working
    /// directory, or a wineserver's server directory named through `known`.
    static func clientPrefix(known: [String: String]) async -> String? {
        let holders = WineOrphans.allProcessIDs().filter { pid in
            WineOrphans.commandLine(of: pid).map { servesCDPPort(commandLine: $0) } ?? false
        }
        for pid in holders {
            guard let directory = WineOrphans.workingDirectory(of: pid) else { continue }
            let canonical = canonicalServerDirectory(directory)
            if let prefix = known[canonical] { return prefix }
            if canonical.hasPrefix("/tmp/.wine-") { continue }
            if let prefix = WineOrphans.prefix(containing: directory) { return prefix }
        }
        return nil
    }

    /// Each bottle folder, keyed by its wineserver's directory.
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
