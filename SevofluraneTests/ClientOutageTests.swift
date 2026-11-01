import Foundation
import Testing
@testable import Sevoflurane

/// The grace a mute client gets during one outage: it grows with the pressure
/// the outage meets and never shrinks under the silence.
struct ClientOutageTests {
    private let muteWindow = 30
    private let began = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        began.addingTimeInterval(seconds)
    }

    @Test
    func `the grace an outage met under load holds once the load has eased`() {
        // The 2026-11-01 shape: silence began under a build (patience 3), the
        // build eased to ordinary (1) after two minutes, the client had been
        // mute for 146 s. Read against the moment, 146 ≥ 30 × 1 × 4 and the
        // client was restarted; the outage remembers the 3.
        var outage = ClientOutage(began: began, patience: 3)
        outage.meet(patience: 1)
        #expect(outage.patience == 3)
        #expect(outage.busyGrace(muteWindow: muteWindow) == 360)
        #expect(outage.busyGraceHolds(muteWindow: muteWindow, at: at(146)))
        #expect(!outage.busyGraceHolds(muteWindow: muteWindow, at: at(360)))
    }

    @Test
    func `pressure that rises during the outage stretches it`() {
        var outage = ClientOutage(began: began, patience: 1)
        #expect(!outage.busyGraceHolds(muteWindow: muteWindow, at: at(130)))
        outage.meet(patience: 2)
        #expect(outage.busyGraceHolds(muteWindow: muteWindow, at: at(130)))
        #expect(outage.muteLongEnough(muteWindow: muteWindow, at: at(60)))
        #expect(!outage.muteLongEnough(muteWindow: muteWindow, at: at(59)))
    }

    @Test
    func `patience below one is one`() {
        #expect(ClientOutage(began: began, patience: 0).patience == 1)
        #expect(ClientOutage(began: began, patience: 0).muteLongEnough(muteWindow: muteWindow, at: at(30)))
    }

    @Test
    func `a run armed in the last three minutes is a game in flight, an older one is not`() {
        let now = at(600)
        #expect(ClientOutage.gameInFlight(armedAt: [at(500)], within: ClientOutage.launchWindow, at: now))
        #expect(!ClientOutage.gameInFlight(armedAt: [at(100)], within: ClientOutage.launchWindow, at: now))
        #expect(!ClientOutage.gameInFlight(armedAt: [], within: ClientOutage.launchWindow, at: now))
    }
}
