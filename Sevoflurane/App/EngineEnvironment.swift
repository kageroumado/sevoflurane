import Foundation

/// The machine-touching half of the Engine pane, split from ``EngineStore``
/// so a simulated environment can pose any set of installed engines and
/// bottles, and can be switched between them — including into a bottle that
/// has to be built from scratch — without stopping Steam or writing a
/// choice anything else would read.
///
/// The live implementation is a facade over globals (`Engine.active`,
/// `SteamBottle.name`) rather than a type of its own, which is exactly why
/// the seam has to exist: a store that reads a global cannot be posed.
@MainActor
protocol EngineEnvironment: AnyObject {
    /// Whether the effects are simulated.
    var isSimulation: Bool { get }

    var activeEngine: Engine { get }
    var activeBottle: String { get }

    /// The bottles this engine keeps. Each engine has its own root, so the
    /// list changes when the staged engine does.
    func bottles(for engine: Engine) -> [SetupDetection.Bottle]

    /// Persists the pair. Nothing has moved yet when this returns — the
    /// caller provisions and restarts.
    func choose(engine: Engine, bottle: String)

    func stopClient(supervisor: ClientSupervisor?) async
    func startClient(supervisor: ClientSupervisor?)
}

extension EngineEnvironment {
    var isSimulation: Bool {
        false
    }
}

/// The real one: the engine and bottle the whole app addresses, and the
/// supervisor that owns the client while they change.
@MainActor
final class LiveEngineEnvironment: EngineEnvironment {
    var activeEngine: Engine {
        Engine.active
    }

    var activeBottle: String {
        SteamBottle.name
    }

    func bottles(for engine: Engine) -> [SetupDetection.Bottle] {
        SetupProbe.bottles(for: engine)
    }

    func choose(engine: Engine, bottle: String) {
        Engine.choose(engine)
        SteamBottle.choose(bottle)
    }

    func stopClient(supervisor: ClientSupervisor?) async {
        await supervisor?.stopForControl()
    }

    func startClient(supervisor: ClientSupervisor?) {
        supervisor?.startForControl()
    }
}
