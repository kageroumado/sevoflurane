import Foundation
import Testing
@testable import Sevoflurane

/// What keeps the app off the bottled client's one DevTools thread: sweeps
/// that join instead of racing.
struct PopupSweeperTests {
    /// A counter the sweep hook increments, so a test can say how many
    /// sweeps actually reached the client.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func bump() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// A one-way switch a sweep hook and a test can both read.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.withLock { value = true }
        }

        var isSet: Bool {
            lock.withLock { value }
        }
    }

    @Test
    func `concurrent asks share one sweep`() async {
        let sweeps = Counter()
        let sweeper = PopupSweeper(minimumInterval: .seconds(30)) { _ in
            // Long enough that every caller below is waiting on this one.
            try? await Task.sleep(for: .milliseconds(200))
            return ["popup \(sweeps.bump())"]
        }
        let names = await withTaskGroup(of: [String].self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await sweeper.sweep().names }
            }
            return await group.reduce(into: [[String]]()) { $0.append($1) }
        }
        #expect(sweeps.count == 1)
        #expect(names.allSatisfy { $0 == ["popup 1"] })
    }

    @Test
    func `a second sweep waits out the minimum interval`() async {
        let sweeps = Counter()
        let sweeper = PopupSweeper(minimumInterval: .milliseconds(300)) { _ in
            ["popup \(sweeps.bump())"]
        }
        let clock = ContinuousClock()
        let began = clock.now
        _ = await sweeper.sweep()
        _ = await sweeper.sweep()
        #expect(sweeps.count == 2)
        #expect(began.duration(to: clock.now) >= .milliseconds(280))
    }

    @Test
    func `a second notification extends the schedule instead of racing it`() async {
        let sweeps = Counter()
        let sweeper = PopupSweeper(
            minimumInterval: .milliseconds(50), scheduleLength: .milliseconds(150),
        ) { _ in
            ["notificationtoasts_\(sweeps.bump())_desktop"]
        }
        let reported = Counter()
        await sweeper.sweepAfterNotification { _ in _ = reported.bump() }
        await sweeper.sweepAfterNotification { _ in _ = reported.bump() }
        // Past the delay before the first sweep and the schedule's own length,
        // so nothing is still in flight.
        try? await Task.sleep(for: .seconds(1))
        #expect(sweeps.count >= 1)
        // One schedule ran, so every sweep was reported exactly once. Two
        // racing schedules would report each other's sweeps as well.
        #expect(reported.count == sweeps.count)
    }

    @Test
    func `a notification during the last sweep extends the schedule`() async {
        let sweeps = Counter()
        let inFirstSweep = Flag()
        let released = Flag()
        let sweeper = PopupSweeper(minimumInterval: .zero, scheduleLength: .milliseconds(100)) { _ in
            let number = sweeps.bump()
            if number == 1 {
                // Held until the second notification is in, which puts it
                // past the first schedule's end and inside its last sweep.
                inFirstSweep.set()
                while !released.isSet { try? await Task.sleep(for: .milliseconds(10)) }
            }
            return ["notificationtoasts_\(number)_desktop"]
        }
        await sweeper.sweepAfterNotification { _ in }
        while !inFirstSweep.isSet { try? await Task.sleep(for: .milliseconds(10)) }
        await sweeper.sweepAfterNotification { _ in }
        released.set()
        for _ in 0 ..< 300 where sweeps.count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(sweeps.count >= 2)
    }

    @Test
    func `a notification's schedule asks only for the twins`() async {
        let scopes = Scopes()
        let sweeper = PopupSweeper(
            minimumInterval: .milliseconds(50), scheduleLength: .milliseconds(150),
        ) { scope in
            scopes.note(scope)
            return ["notificationtoasts_1_desktop"]
        }
        await sweeper.sweepAfterNotification { _ in }
        // The schedule waits out `firstSweepDelay` and then sweeps on a task
        // of its own, so how soon the first scope arrives is up to the
        // machine: waiting a fixed span asserts that this Mac dispatches
        // promptly. Wait for the scope instead, and only give up on it after
        // long enough that a busy host is not the reason.
        for _ in 0 ..< 200 where scopes.taken.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(!scopes.taken.isEmpty)
        #expect(scopes.taken.allSatisfy { $0 == .twins })
    }

    @Test
    func `a sweep says what it was allowed to hide`() async {
        let sweeper = PopupSweeper(minimumInterval: .zero) { _ in ["SP Desktop_uid0"] }
        #expect(await sweeper.sweep().scope == .everything)
        #expect(await sweeper.sweep(.twins).names == ["SP Desktop_uid0"])
    }

    /// The scopes the hook was asked for, in order.
    private final class Scopes: @unchecked Sendable {
        private let lock = NSLock()
        private var scopes: [PopupSweepScope] = []

        func note(_ scope: PopupSweepScope) {
            lock.lock()
            defer { lock.unlock() }
            scopes.append(scope)
        }

        var taken: [PopupSweepScope] {
            lock.lock()
            defer { lock.unlock() }
            return scopes
        }
    }
}

/// Which of the client's own windows a notification's sweep may put away: the
/// copies of what this app draws itself, and nothing the client alone has.
struct PopupSweepClassificationTests {
    private func allowed(_ name: String) -> Bool {
        let base = SteamWindowRole.base(ofPopupNamed: name)
        return SteamWindowRole.twinNames.contains { $0.matches(base: base) }
    }

    @Test
    func `the windows this app draws itself are twins`() {
        #expect(allowed("notificationtoasts_1_desktop"))
        #expect(allowed("SP Desktop_uid0"))
        #expect(allowed("chat_76561198000000000_uid0"))
        #expect(allowed("friendslist_uid0"))
    }

    @Test
    func `the windows only the client has are left alone`() {
        // The retest's three: the install and EULA modal, a game's own popup,
        // and the sign-in window a base prefix would otherwise swallow.
        #expect(!allowed("PopupWindow_InstallModal_«rg»"))
        #expect(!allowed("Megabonk_uid0"))
        #expect(!allowed("SP DesktopLoginWindow_uid0"))
        #expect(!allowed("contextmenu_10_uid0"))
        #expect(!allowed("SP Keyboard_uid0"))
        #expect(!allowed("desktopoverlay_uid2220"))
    }

    @Test
    func `every twin name belongs to a twin role`() {
        for name in ["notificationtoasts_1_desktop", "SP Desktop_uid0", "chat_1_uid0"] {
            #expect(SteamWindowRole.twinRoles.contains(SteamWindowRole(popupName: name)))
        }
        for name in ["PopupWindow_InstallModal_«rg»", "Megabonk_uid0", "SP DesktopLoginWindow"] {
            #expect(!SteamWindowRole.twinRoles.contains(SteamWindowRole(popupName: name)))
        }
    }
}

/// Which of the client's popups a sweep leaves alone while a launch is
/// waiting on one of them.
struct PopupSparingTests {
    @Test
    func `the launch's own popup is spared by name`() {
        let sparing = PopupSparing(exactBases: ["Black Myth: Wukong Benchmark Tool"])
        #expect(sparing.spares(popupNamed: "Black Myth: Wukong Benchmark Tool_uid0"))
        #expect(!sparing.spares(popupNamed: "Megabonk_uid0"))
    }

    @Test
    func `a desktop popup the role table cannot name is spared when asked`() {
        let sparing = PopupSparing(unclassifiedDesktopPopups: true)
        #expect(sparing.spares(popupNamed: "Megabonk_uid0"))
        #expect(!sparing.spares(popupNamed: "notificationtoasts_1_desktop"))
        #expect(!sparing.spares(popupNamed: "SP Desktop_uid0"))
        #expect(!sparing.spares(popupNamed: "PopupWindow_InstallModal_«rg»"))
        // A game overlay's popup carries the game's pid and is never a launch dialog.
        #expect(!sparing.spares(popupNamed: "friendslist_uid2220"))
    }

    @Test
    func `nothing is spared by default`() {
        for name in ["Black Myth: Wukong Benchmark Tool_uid0", "Megabonk_uid0", "SP Desktop_uid0"] {
            #expect(!PopupSparing.none.spares(popupNamed: name))
        }
    }

    @Test
    func `the sweep script carries the spared name`() {
        let script = SteamBridge.popupHideScript(
            .everything, sparing: PopupSparing(exactBases: ["Black Myth: Wukong Benchmark Tool"], unclassifiedDesktopPopups: true),
        )
        #expect(script.contains("\"Black Myth: Wukong Benchmark Tool\""))
        #expect(script.contains("true"))
        #expect(SteamBridge.popupHideScript(.everything).contains("[], false"))
    }
}
