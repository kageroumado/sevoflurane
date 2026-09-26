import Foundation

extension BottleSupervisor {
    /// Whether the client answering CDP may be adopted as this bottle's.
    ///
    /// Every cycle compares the bottle the client booted in with the
    /// configured one, which costs two preference reads. With `sweep` it also
    /// looks at the machine (``BottleIdentity/verify(configured:)``): at the
    /// first sighting of a client and every eighth healthy cycle with no game up. A client of
    /// another Sevoflurane bottle is stopped and the configured bottle's
    /// started in its place; another Sevoflurane bottle's wineserver is
    /// stopped; a client in a prefix outside Sevoflurane's bottles is left
    /// alone and not adopted.
    func confirmClientIdentity(sweep: Bool) async -> Bool {
        let configured = BottleTarget.configured
        if let booted = BootedBottle.target,
           BottleIdentity.bottleMoved(booted: booted.path, configured: configured.path) {
            await replaceClient(
                stopping: [booted],
                because: "the client booted in bottle \(booted.name), and the bottle is \(configured.name) now",
            )
            return false
        }
        guard sweep else { return true }
        let verdict = await BottleIdentity.verify(configured: configured)
        if let outside = verdict.outsideClient {
            if reportedOutsideClient != outside {
                reportedOutsideClient = outside
                log.log(
                    .supervisor,
                    "identity: the client answering :\(BridgePorts.cdp) runs in the Wine prefix "
                        + "\((outside as NSString).lastPathComponent), outside Sevoflurane's bottles — "
                        + "not adopting it, and not stopping it",
                )
            }
            fault = .degraded("a Steam outside Sevoflurane's bottles holds the client's port")
            return false
        }
        reportedOutsideClient = nil
        if let foreign = verdict.foreignClient {
            await replaceClient(
                stopping: verdict.strays.map(\.target),
                because: "the client answering :\(BridgePorts.cdp) runs in bottle \(foreign.name), "
                    + "where the configured bottle is \(configured.name)",
            )
            return false
        }
        if !verdict.extras.isEmpty {
            for extra in verdict.extras {
                log.log(
                    .supervisor,
                    "identity: bottle \(extra.name) has a wineserver running beside the configured "
                        + "\(configured.name) — stopping \(extra.name)",
                )
            }
            await ClientLifecycle.stopAll(gracePolls: 5, targets: verdict.extras.map(\.target))
        }
        return true
    }

    /// The Sevoflurane bottles running beside the booted and the configured
    /// one, each logged with what it is, so a stop can reach them too.
    func strayBottles(during occasion: String, beside booted: BottleTarget?) async -> [BottleTarget] {
        let configured = BottleTarget.configured
        let verdict = await BottleIdentity.verify(configured: configured)
        let reached = BottleTarget.stopSet(booted: booted, configured: configured)
        var strays: [BottleTarget] = []
        for stray in verdict.strays where !reached.contains(stray.target) {
            let what = stray == verdict.foreignClient
                ? "the client answering :\(BridgePorts.cdp) runs there"
                : "a wineserver runs there"
            log.log(
                .supervisor,
                "\(occasion): bottle \(stray.name) is not the configured \(configured.name) and \(what) — stopping it too",
            )
            strays.append(stray.target)
        }
        return strays
    }

    /// Stops `targets` and, when a client is wanted and the configured bottle
    /// can run one, starts it there through the ladder.
    private func replaceClient(stopping targets: [BottleTarget], because cause: String) async {
        let names = targets.map(\.name).joined(separator: ", ")
        let configured = BottleTarget.configured
        if wantsClient, !provisioningBlocksStart(reason: cause) {
            log.log(.supervisor, "identity: \(cause) — stopping \(names), then starting the client in \(configured.name)")
            await restartClient(reason: cause, fullWindows: true)
            return
        }
        log.log(
            .supervisor,
            "identity: \(cause) — stopping \(names); no client starts in \(configured.name) "
                + (wantsClient ? "until the bottle is ready" : "until one is asked for"),
        )
        await app.duringClientStop {
            await ClientLifecycle.stopAll(gracePolls: 10, targets: targets, hidingPopups: true)
        }
    }
}
