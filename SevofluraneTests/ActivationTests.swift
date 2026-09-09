import AppKit
import Testing
@testable import Sevoflurane

/// An ``ActivationSurface`` that records the calls instead of making them, and
/// answers `frontmostPID` from a script so a test can say on which attempt the
/// window server gives in.
@MainActor
final class RecordingActivationSurface: ActivationSurface {
    enum Step: Equatable {
        case promoteToRegular
        case activateSelf
        case activateSelfWithAllWindows
        case turnRunLoop
        case yield(pid_t)
        case activate(pid_t)
        case wait(Duration)
    }

    private(set) var steps: [Step] = []
    private(set) var lines: [String] = []

    var appIsActive = false
    var appPolicy: NSApplication.ActivationPolicy = .accessory
    var running: Set<pid_t> = []
    /// What `activate(pid:)` returns, in order; the last value repeats.
    var accepts: [Bool] = [true]
    /// Which pid is frontmost after each attempt, in order; the last repeats.
    var frontmostByAttempt: [pid_t?] = [nil]

    private var attempts = 0

    var frontmostPID: pid_t? {
        guard attempts > 0 else { return nil }
        return frontmostByAttempt[min(attempts, frontmostByAttempt.count) - 1]
    }

    func isRunning(_ pid: pid_t) -> Bool { running.contains(pid) }

    func promoteToRegular() {
        appPolicy = .regular
        steps.append(.promoteToRegular)
    }

    func activateSelf() {
        appIsActive = true
        steps.append(.activateSelf)
    }

    func activateSelfWithAllWindows() {
        steps.append(.activateSelfWithAllWindows)
    }

    func turnRunLoop() async {
        steps.append(.turnRunLoop)
    }

    func yieldActivation(to pid: pid_t) {
        steps.append(.yield(pid))
    }

    func activate(pid: pid_t) -> Bool {
        steps.append(.activate(pid))
        attempts += 1
        return accepts[min(attempts, accepts.count) - 1]
    }

    func wait(_ duration: Duration) async {
        steps.append(.wait(duration))
    }

    func log(_ line: String) {
        lines.append(line)
    }

    var activateCount: Int { steps.count { if case .activate = $0 { true } else { false } } }
    var waitCount: Int { steps.count { if case .wait = $0 { true } else { false } } }
}

@MainActor
struct ActivationTests {
    private let game: pid_t = 4242

    private func surface(frontmostByAttempt: [pid_t?] = [nil]) -> RecordingActivationSurface {
        let surface = RecordingActivationSurface()
        surface.running = [game]
        surface.frontmostByAttempt = frontmostByAttempt
        return surface
    }

    @Test
    func `an inactive accessory app takes the right before it spends it`() async {
        let surface = surface(frontmostByAttempt: [game])
        await Activation(surface: surface).bringForward(pid: game, describedAs: "the game")
        #expect(surface.steps == [
            .promoteToRegular, .activateSelf, .turnRunLoop, .yield(game), .activate(game),
        ])
    }

    @Test
    func `an app that is already active neither promotes nor turns the run loop`() async {
        let surface = surface(frontmostByAttempt: [game])
        surface.appIsActive = true
        surface.appPolicy = .regular
        await Activation(surface: surface).bringForward(pid: game, describedAs: "the game")
        #expect(surface.steps == [.yield(game), .activate(game)])
    }

    @Test
    func `the yield and activate pair is retried until the target is frontmost`() async {
        let surface = surface(frontmostByAttempt: [nil, nil, game])
        let front = await Activation(surface: surface)
            .bringForward(pid: game, describedAs: "the game")
        #expect(front)
        #expect(surface.steps == [
            .promoteToRegular, .activateSelf, .turnRunLoop,
            .yield(game), .activate(game),
            .wait(Activation.retryEvery), .yield(game), .activate(game),
            .wait(Activation.retryEvery), .yield(game), .activate(game),
        ])
    }

    @Test
    func `the retry budget is one attempt every five hundred milliseconds for five seconds`() async {
        let surface = surface()
        let front = await Activation(surface: surface)
            .bringForward(pid: game, describedAs: "the game")
        #expect(!front)
        #expect(Activation.attemptLimit == 11)
        #expect(surface.activateCount == Activation.attemptLimit)
        #expect(surface.waitCount == Activation.attemptLimit - 1)
        #expect(Activation.retryEvery * (Activation.attemptLimit - 1) == Activation.retryBudget)
    }

    @Test
    func `a pid with no process behind it is refused before any activation`() async {
        let surface = surface()
        surface.running = []
        let front = await Activation(surface: surface)
            .bringForward(pid: game, describedAs: "the game")
        #expect(!front)
        #expect(surface.steps.isEmpty)
        #expect(surface.lines.count == 1)
        #expect(surface.lines[0].contains("no app to activate"))
    }

    @Test
    func `every attempt logs the state, the return value and who ended up in front`() async {
        let surface = surface(frontmostByAttempt: [nil, 99])
        await Activation(surface: surface).bringForward(pid: game, describedAs: "the game")
        #expect(surface.lines.count == surface.activateCount)
        for line in surface.lines {
            #expect(line.contains("the game"))
            #expect(line.contains("activate returned"))
            #expect(line.contains("frontmost pid"))
            #expect(line.contains("active") || line.contains("inactive"))
            #expect(line.contains("regular") || line.contains("accessory"))
        }
        #expect(surface.lines.last?.contains("frontmost pid 99") == true)
    }

    @Test
    func `claiming the right on an active app changes nothing`() {
        let surface = surface()
        surface.appIsActive = true
        #expect(!Activation(surface: surface).claimRight())
        #expect(surface.steps.isEmpty)
    }

    @Test
    func `bringing this app forward pairs the two calls`() {
        let surface = surface()
        Activation(surface: surface).bringAppForward()
        #expect(surface.steps == [.promoteToRegular, .activateSelf, .activateSelfWithAllWindows])
    }
}
