import Foundation

/// The settings whose sink is the prefix's registry rather than an env file,
/// written under the bottle's own key and under `AppDefaults\<exe>` for a game
/// that sets one.
///
/// Wine opens both keys at process start — `winemac.drv` `setup_options`,
/// win32u's `X11 Driver` pass, and the loader's `DllOverrides` — so a value
/// written now is what the next game process reads, with the client left
/// running. Writes go through the engine's `reg.exe`, the way provisioning
/// writes the tray and SDL values; `user.reg` is the wineserver's to edit.
///
/// `<prefix>/.sevo/registry.json` records what the last pass wrote, so a pass
/// that changes nothing spawns nothing, and a value the store no longer sets
/// is deleted rather than left to outlive its setting. The record is what
/// makes this cheap enough to run at every store change and every client
/// start, and it is the only reader: `user.reg` lags a write by seconds, so a
/// file scan would ask a stale question.
nonisolated enum ConfigRegistry {
    /// One value under `HKCU\Software\Wine`.
    struct Entry: Hashable, Codable, Sendable {
        /// The key below `Software\Wine`, such as `Mac Driver` or
        /// `AppDefaults\game.exe\DllOverrides`.
        let key: String
        let name: String
        let value: String

        /// The full path `reg.exe` takes.
        var path: String {
            #"HKCU\Software\Wine\"# + key
        }
        /// What identifies this value wherever it is, so a changed value is
        /// one write and a dropped setting is one delete.
        var place: String {
            "\(key)\\\(name)"
        }
    }

    /// Wine's own spelling for a switch, which it reads by first character.
    private static func flag(_ on: Bool) -> String {
        on ? "Y" : "N"
    }

    // MARK: - What the store asks for

    /// Every value the hierarchy asks the registry to hold, in a stable order.
    ///
    /// Retina is bottle-wide alone: `winemac.drv` reads `RetinaMode` with no
    /// app key, so that the DPI and the monitor sizes are the same for every
    /// process in the prefix, and a per-program copy would sit there unread.
    static func desired(bottle name: String) -> [Entry] {
        var entries = [
            Entry(
                key: "Mac Driver", name: "RetinaMode",
                value: flag(GameConfig.retina(bottle: name).value),
            ),
            Entry(
                key: "X11 Driver", name: "EmulateModeset",
                value: flag(GameConfig.emulateModeset(bottle: name).value),
            ),
        ]
        for values in GameConfig.games().values {
            for exe in values.exes ?? [] {
                if let modeset = values.emulateModeset {
                    entries.append(Entry(
                        key: #"AppDefaults\\#(exe)\X11 Driver"#,
                        name: "EmulateModeset", value: flag(modeset),
                    ))
                }
                for (dll, mode) in values.dllOverrides ?? [:] {
                    entries.append(Entry(
                        key: #"AppDefaults\\#(exe)\DllOverrides"#,
                        name: dll, value: mode,
                    ))
                }
            }
        }
        return entries.sorted { $0.place < $1.place }
    }

    // MARK: - Applying

    /// Queues a pass that brings the prefix's registry in line with the store.
    /// The app's process outlives the write, so it does not wait.
    static func apply(bottle name: String, prefix: URL) {
        Task(name: "Registry settings") { await settle(bottle: name, prefix: prefix) }
    }

    /// Runs a pass after every pass already queued, and waits for it — what a
    /// command line does before it exits, since a process that ends takes its
    /// unfinished writes with it. Passes run one at a time and in order, so two
    /// changes in a row cannot write their values the wrong way round.
    static func settle(bottle name: String, prefix: URL) async {
        await Writer.shared.enqueue { await reconcile(bottle: name, prefix: prefix) }
    }

    /// The one pass: write what changed, delete what the store dropped, and
    /// record what landed. A value whose `reg.exe` failed stays out of the
    /// record, so the next pass tries it again.
    static func reconcile(bottle name: String, prefix: URL) async {
        let wanted = desired(bottle: name)
        let written = record(prefix: prefix)
        guard Set(wanted) != Set(written) else { return }

        let wantedPlaces = Set(wanted.map(\.place))
        let writtenSet = Set(written)
        var landed: [Entry] = []
        for entry in wanted {
            guard !writtenSet.contains(entry) else {
                landed.append(entry)
                continue
            }
            if await run(["reg", "add", entry.path, "/v", entry.name, "/d", entry.value, "/f"]) {
                landed.append(entry)
            }
        }
        for entry in written where !wantedPlaces.contains(entry.place) {
            _ = await run(["reg", "delete", entry.path, "/v", entry.name, "/f"])
        }
        setRecord(landed, prefix: prefix)
    }

    private static func run(_ program: [String]) async -> Bool {
        let result = await ClientLifecycle.runInBottle(program, timeout: .seconds(60))
        guard result.status == 0 else {
            SetupLog.log("registry: \(program.joined(separator: " ")) failed: "
                + result.output.suffix(200))
            return false
        }
        return true
    }

    // MARK: - The record

    static func recordURL(prefix: URL) -> URL {
        prefix.appendingPathComponent(".sevo/registry.json")
    }

    static func record(prefix: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: recordURL(prefix: prefix)),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    static func setRecord(_ entries: [Entry], prefix: URL) {
        let url = recordURL(prefix: prefix)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The one lane every pass runs in, in arrival order.
    private actor Writer {
        static let shared = Writer()
        private var tail: Task<Void, Never>?

        func enqueue(_ body: @escaping @Sendable () async -> Void) async {
            let previous = tail
            let job = Task {
                await previous?.value
                await body()
            }
            tail = job
            await job.value
        }
    }
}
