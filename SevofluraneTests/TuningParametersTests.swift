import Testing
@testable import Sevoflurane

/// The thread-waiting presets and the numbers behind the custom one.
struct TuningParametersTests {
    @Test
    func `each preset stands for its parameters, and custom for the ones it is given`() {
        let own = TuningParameters(waitSpin: 900, adaptive: false, objectSpin: 40)
        #expect(PerformanceTuning.standard.parameters(custom: own) == .standard)
        #expect(PerformanceTuning.experimental.parameters(custom: own) == .experimental)
        #expect(PerformanceTuning.custom.parameters(custom: own) == own)
        #expect(PerformanceTuning.custom.parameters(custom: nil) == .experimental)
    }

    @Test
    func `the environment names all three switches, and clamps a spin the engine would not take`() {
        let wild = TuningParameters(waitSpin: -5, adaptive: true, objectSpin: 9_000_000)
        let environment = Dictionary(uniqueKeysWithValues: wild.environment.map { ($0.key, $0.value) })
        #expect(environment == [
            "SEVO_WAIT_SPIN": "0", "SEVO_WAIT_SPIN_ADAPT": "1", "SEVO_OBJECT_SPIN": "1000000",
        ])
    }

    @Test
    func `the command line's spelling reads back as written`() {
        let parameters = TuningParameters(argument: "5200,1,300")
        #expect(parameters == TuningParameters(waitSpin: 5200, adaptive: true, objectSpin: 300))
        #expect(parameters?.argument == "5200,1,300")
    }

    @Test
    func `a malformed or out-of-range spelling is refused`() {
        for argument in ["", "5200", "5200,1", "a,1,2", "5200,2,5200", "5200,1,-1", "2000000,0,0"] {
            #expect(TuningParameters(argument: argument) == nil, "\(argument)")
        }
    }
}
