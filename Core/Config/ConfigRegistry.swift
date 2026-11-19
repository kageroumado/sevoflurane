import Foundation

/// The settings that live in the prefix's registry, under the bottle's key and
/// `AppDefaults\<exe>`, read by Wine at every process start. Writes go through
/// the engine's `reg.exe`, since `user.reg` is the wineserver's to edit.
///
/// `<prefix>/.sevo/registry.json` records the last pass, so an unchanged pass
/// spawns nothing and a dropped setting is deleted. It is the only reader:
/// `user.reg` lags a write by seconds.
nonisolated enum ConfigRegistry {
    /// One value under `HKCU\Software\Wine`.
    struct Entry: Hashable, Codable, Sendable {
        /// The key below `Software\Wine`, such as `Mac Driver` or
        /// `AppDefaults\game.exe\DllOverrides`.
        let key: String
        let name: String
        let value: String

        var path: String {
            #"HKCU\Software\Wine\"# + key
        }
        /// The value's identity, whatever it holds.
        var place: String {
            "\(key)\\\(name)"
        }
    }

    /// Wine reads a switch by its first character.
    private static func flag(_ on: Bool) -> String {
        on ? "Y" : "N"
    }

    // MARK: - What the store asks for

    /// Every value the hierarchy asks for, in a stable order. `RetinaMode` is
    /// bottle-wide only: `winemac.drv` reads it with no app key.
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
            entries += gameEntries(values)
        }
        return entries.sorted { $0.place < $1.place }
    }

    /// One game's values, under each of its executables.
    static func gameEntries(_ values: ConfigValues) -> [Entry] {
        var entries: [Entry] = []
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
        return entries
    }

    // MARK: - Applying

    /// Queues a pass without waiting.
    static func apply(bottle name: String, prefix: URL) {
        Task(name: "Registry settings") { await settle(bottle: name, prefix: prefix) }
    }

    /// Queues a pass and waits for it, as a command line must before exiting.
    /// Passes run one at a time, in order.
    static func settle(bottle name: String, prefix: URL) async {
        await Writer.shared.enqueue { await reconcile(bottle: name, prefix: prefix) }
    }

    /// Writes what changed, deletes what was dropped, and records what landed,
    /// so a failed write is retried next pass.
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
