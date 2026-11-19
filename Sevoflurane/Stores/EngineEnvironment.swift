import Foundation

/// The machine-touching half of the Engine pane, split from ``EngineStore`` so
/// a simulated environment can pose any engines and bottles and switch between
/// them without stopping Steam or writing a real choice. The live one is a
/// facade over globals (`Engine.active`, `SteamBottle.name`), which a store
/// cannot pose directly.
@MainActor
protocol EngineEnvironment: AnyObject {
    /// Whether the effects are simulated.
    var isSimulation: Bool { get }

    var activeEngine: Engine { get }
    var activeBottle: String { get }

    /// The bottles this engine keeps; each engine has its own root.
    func bottles(for engine: Engine) -> [SetupDetection.Bottle]

    /// Persists the pair; the caller provisions and restarts.
    func choose(engine: Engine, bottle: String)

    func stopClient(supervisor: ClientSupervisor?) async
    func startClient(supervisor: ClientSupervisor?)
}

extension EngineEnvironment {
    var isSimulation: Bool {
        false
    }
}

/// The real one: the engine and bottle the whole app addresses.
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
