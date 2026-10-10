import Foundation
import Synchronization
import Testing
@testable import Sevoflurane

/// The ladder that ends a game's processes before Steam is asked to.
struct GameEndingTests {
    @Test
    func `processes that leave on SIGTERM are never sent SIGKILL and the wait ends with them`() async {
        let machine = FakeProcesses([
            11: .dies(on: SIGTERM, after: .milliseconds(150)),
            12: .dies(on: SIGTERM, after: .zero),
        ])
        let outcome = await GameEnding.end([11, 12], processes: machine)
        #expect(outcome == GameEnding.Outcome(terminated: [11, 12]))
        #expect(machine.signals == [.init(pid: 11, signal: SIGTERM, at: .zero), .init(pid: 12, signal: SIGTERM, at: .zero)])
        // Two polls after the first process, and none past the last one.
        #expect(machine.clock == .milliseconds(200))
    }

    @Test
    func `a process that ignores SIGTERM is killed once the grace has passed`() async {
        let machine = FakeProcesses([
            21: .dies(on: SIGTERM, after: .zero),
            22: .dies(on: SIGKILL, after: .milliseconds(50)),
        ])
        let outcome = await GameEnding.end([21, 22], grace: .seconds(1), processes: machine)
        #expect(outcome == GameEnding.Outcome(terminated: [21], killed: [22]))
        let kills = machine.signals.filter { $0.signal == SIGKILL }
        #expect(kills == [.init(pid: 22, signal: SIGKILL, at: .seconds(1))])
        #expect(machine.clock == .seconds(1) + .milliseconds(100))
    }

    @Test
    func `a process that outlives SIGKILL is reported, after the kill grace`() async {
        let machine = FakeProcesses([31: .immortal])
        let outcome = await GameEnding.end([31], grace: .milliseconds(300), processes: machine)
        #expect(outcome == GameEnding.Outcome(survivors: [31]))
        #expect(machine.signals.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(machine.clock == .milliseconds(300) + GameEnding.killGrace)
    }

    @Test
    func `a process already gone is left alone`() async {
        let machine = FakeProcesses([41: .gone, 42: .dies(on: SIGTERM, after: .zero)])
        let outcome = await GameEnding.end([41, 42], processes: machine)
        #expect(outcome == GameEnding.Outcome(terminated: [42]))
        #expect(machine.signals.map(\.pid) == [42])
        #expect(await GameEnding.end([41], processes: machine).isEmpty)
    }

    @Test
    func `the summary names what each step did`() {
        #expect(GameEnding.Outcome().summary == nil)
        #expect(GameEnding.Outcome(terminated: [1, 2]).summary == "game processes: 2 processes ended on SIGTERM")
        #expect(
            GameEnding.Outcome(terminated: [1], killed: [2], survivors: [3]).summary
                == "game processes: 1 process ended on SIGTERM, 1 process needed SIGKILL, 1 process survived: [3]",
        )
    }

    @Test
    func `a stop on record makes an exit status of 0 a stop, and a crash stays a crash`() {
        func kind(_ code: Int?, stop: RunLog.StopSource?, crash: RunRecord.Crash? = nil) -> RunRecord.Exit.Kind {
            RunInProgress.kind(
                code: code, ending: .init(crash: crash), endedNotResponding: false, stopRequest: stop,
                steamError: nil, unrecorded: .unknown,
            )
        }
        #expect(kind(0, stop: .player) == .stopped)
        #expect(kind(0, stop: .tool) == .stoppedByTool)
        #expect(kind(1, stop: .player) == .stopped)
        #expect(kind(0, stop: nil) == .user)
        #expect(kind(1, stop: nil) == .exitError)
        #expect(kind(0, stop: .tool, crash: .init(code: "0xc0000005")) == .crash)
    }
}

/// A machine whose processes die on the signal each was told to, a set time
/// after it, with a clock that only the ladder's own sleeps advance.
final class FakeProcesses: GameEnding.Processes {
    enum Fate: Equatable {
        case dies(on: Int32, after: Duration)
        case immortal
        case gone
    }

    struct Sent: Equatable {
        let pid: pid_t
        let signal: Int32
        let at: Duration
    }

    private struct State {
        var fates: [pid_t: Fate]
        var deaths: [pid_t: Duration] = [:]
        var signals: [Sent] = []
        var clock: Duration = .zero
    }

    private let state: Mutex<State>

    init(_ fates: [pid_t: Fate]) {
        state = Mutex(State(fates: fates))
    }

    var signals: [Sent] { state.withLock { $0.signals } }
    var clock: Duration { state.withLock { $0.clock } }

    func isAlive(_ pid: pid_t) -> Bool {
        state.withLock { state in
            guard let fate = state.fates[pid], fate != .gone else { return false }
            guard let death = state.deaths[pid] else { return true }
            return state.clock < death
        }
    }

    func signal(_ pid: pid_t, _ signal: Int32) {
        state.withLock { state in
            state.signals.append(Sent(pid: pid, signal: signal, at: state.clock))
            if case let .dies(on: lethal, after: delay)? = state.fates[pid], lethal == signal,
               state.deaths[pid] == nil {
                state.deaths[pid] = state.clock + delay
            }
        }
    }

    func sleep(_ duration: Duration) async {
        state.withLock { $0.clock += duration }
    }
}
