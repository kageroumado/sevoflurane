import Foundation

/// Keeps Steam's list of non-Steam games in step with the adopted programs
/// (``SteamShortcuts``): a pass reads the list from the client, plans, and
/// makes the changes with the client's own calls.
///
/// A pass runs when the client becomes healthy, when a program is added or
/// removed, and when its "Show in Steam's library" switch changes. With the
/// client down a pass changes nothing and the next healthy client catches up,
/// so a program added or removed meanwhile, by the app or by `sevo`, reaches
/// Steam then.
@MainActor
final class SteamLibraryShortcuts {
    static let shared = SteamLibraryShortcuts()

    /// The connection to the client. Set once the bridge is up.
    var bridge: SteamBridge?
    /// Told shortcut app id → program id whenever it may have changed, so
    /// Steam's launch events resolve to the program (``SteamWebHost/shortcutPrograms``).
    var onAliases: (([Int: Int]) -> Void)?

    private var pass: Task<Void, Never>?
    private var wantsAnotherPass = false
    /// Shortcuts made in this session, by when: Steam's list can lag a
    /// moment behind the call that made one.
    private var made: [Int: ContinuousClock.Instant] = [:]
    private static let freshFor: Duration = .seconds(60)

    /// Whether a program can be listed at all: it lives in the bottle the
    /// Steam client runs in, it is played rather than installed from, and it
    /// does not need a `steam.exe` parent with no client beside it
    /// (``SteamParent``), which a launch from Steam's library cannot give.
    static func canList(_ program: AdoptedProgram) -> Bool {
        program.bottle == SteamBottle.name && program.kind != ProgramKind.installer
            && !SteamParent.wants(program)
    }

    /// Lists a program in Steam's library or takes it out.
    func setListed(_ listed: Bool, programID: Int) {
        AdoptedPrograms.update(programID) { $0.inSteamLibrary = listed }
        sync()
    }

    /// Brings Steam's list in step. Calls made while a pass runs are answered
    /// by one more pass after it.
    func sync() {
        guard pass == nil else {
            wantsAnotherPass = true
            return
        }
        pass = Task(name: "Bring Steam's non-Steam games in step") {
            repeat {
                wantsAnotherPass = false
                await runPass()
            } while wantsAnotherPass
            pass = nil
        }
    }

    private func runPass() async {
        let entries = AdoptedPrograms.all()
        onAliases?(SteamShortcuts.aliases(entries))
        guard let bridge,
              let json = await bridge.evaluateInClient(SteamShortcuts.listScript, cap: .seconds(10)),
              let listed = try? JSONDecoder().decode([SteamShortcuts.Listed].self, from: Data(json.utf8))
        else { return }
        let now = ContinuousClock.now
        made = made.filter { now - $0.value < Self.freshFor }
        let plan = SteamShortcuts.plan(
            entries.map(Self.weighed), listed: listed, owned: SteamShortcuts.owned(), fresh: Set(made.keys),
        )
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        if !plan.removed.isEmpty {
            _ = await bridge.evaluateInClient(SteamShortcuts.removeScript(plan.removed))
            EventLog.shared.log(.client, "took \(plan.removed.count) program(s) out of Steam's library")
        }
        for id in plan.withdrawn {
            AdoptedPrograms.update(id) {
                $0.inSteamLibrary = false
                $0.steamShortcutID = nil
            }
            EventLog.shared.log(.client, "\(byID[id]?.name ?? String(id)) was removed from Steam's library in Steam")
        }
        for id in plan.forgotten {
            AdoptedPrograms.update(id) { $0.steamShortcutID = nil }
        }
        for (id, shortcut) in plan.kept {
            AdoptedPrograms.update(id) { $0.steamShortcutID = shortcut }
        }
        var owned = Set(plan.kept.values).union(plan.removed)
        for id in plan.added {
            guard let entry = byID[id] else { continue }
            if let shortcut = await add(entry, bridge: bridge) {
                owned.insert(shortcut)
            }
        }
        SteamShortcuts.setOwned(owned)
        onAliases?(SteamShortcuts.aliases(AdoptedPrograms.all()))
    }

    /// Makes one program's shortcut and records its app id.
    private func add(_ entry: AdoptedPrograms.Entry, bridge: SteamBridge) async -> Int? {
        let script = SteamShortcuts.addScript(
            name: entry.name, exe: SteamBottle.windowsPath(for: entry.program.url),
            launchOptions: SteamShortcuts.launchOptions(entry.program.arguments),
        )
        guard let answer = await bridge.evaluateInClient(script), let shortcut = Int(answer) else {
            EventLog.shared.log(.client, "could not add \(entry.name) to Steam's library: the client made no shortcut")
            return nil
        }
        made[shortcut] = .now
        AdoptedPrograms.update(entry.id) { $0.steamShortcutID = shortcut }
        EventLog.shared.log(.client, "added \(entry.name) to Steam's library as \(shortcut)")
        return shortcut
    }

    /// A program as the plan weighs it.
    private static func weighed(_ entry: AdoptedPrograms.Entry) -> SteamShortcuts.Program {
        SteamShortcuts.Program(
            id: entry.id,
            exe: SteamShortcuts.exeKey(SteamBottle.windowsPath(for: entry.program.url)),
            wanted: entry.program.inSteamLibrary == true && canList(entry.program),
            shortcutID: entry.program.steamShortcutID,
        )
    }
}
