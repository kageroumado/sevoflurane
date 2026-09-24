#if DEBUG
    import Foundation

    /// A ``StorageEnvironment`` with nothing on disk behind it: fixture sizes,
    /// a fixture library, and an uninstall that can be walked all the way to
    /// the last dialog without taking anything to the Trash.
    @MainActor
    final class DemoStorageEnvironment: StorageEnvironment {
        /// The libraries the pane has to lay out.
        enum Scenario: String, CaseIterable, Identifiable {
            /// A large library — the numbers that make this pane's job plain.
            case library
            /// Freshly provisioned: Steam is installed and no game is.
            case empty
            /// Sizes that arrive slowly, one row at a time, so the header's
            /// spinner and the filling rows can be seen.
            case measuringSlowly = "measuring-slowly"
            /// Games sitting in other bottles that this one could link to
            /// instead of downloading again.
            case linkableGames = "linkable-games"
            /// Two games already linked into another bottle, so the unlink
            /// path and the restart notice have somewhere to happen.
            case alreadyLinked = "already-linked"

            var id: String {
                rawValue
            }

            var title: String {
                switch self {
                case .library: "Full library"
                case .empty: "Nothing installed"
                case .measuringSlowly: "Still measuring"
                case .linkableGames: "Games worth linking"
                case .alreadyLinked: "Games already linked"
                }
            }
        }

        let isSimulation = true

        private let scenario: Scenario
        /// Held here rather than recomputed, so a row this environment has
        /// already been asked to trash stays at zero.
        private var sizes: [String: Int64]
        /// The app IDs this bottle holds as links into another one.
        private var linked: Set<Int> = []
        /// Games another bottle has that this one does not, minus the ones
        /// already linked in this session.
        private var candidates: [SharedGames.Candidate] = []
        /// Programs this session has been asked to forget.
        private var removedPrograms: Set<Int> = []

        init(scenario: Scenario) {
            self.scenario = scenario
            sizes = switch scenario {
            case .empty:
                [
                    "games": 0, "client": 1_932_735_283, "caches": 141_557_760,
                    "bottle": 692_060_160, "engines": 1_395_864_371, "renderers": 0,
                    "shaders": 0, "toolkits": 0, "shadow": 0, "logs": 88124,
                ]
            case .library, .measuringSlowly, .linkableGames, .alreadyLinked:
                [
                    "games": 214_863_953_920, "programs": 6_871_947_674,
                    "client": 1_932_735_283, "caches": 3_221_225_472,
                    "bottle": 692_060_160, "engines": 1_395_864_371, "renderers": 61_865_984,
                    "shaders": 38_797_312, "toolkits": 205_520_896, "shadow": 4096, "logs": 2_411_724,
                ]
            }
            linked = scenario == .alreadyLinked ? [1_245_620, 892_970] : []
            log("scenario '\(scenario.rawValue)' — nothing will be moved to the Trash")
        }

        func entries() -> [StorageInventory.Entry] {
            StorageInventory.entries()
        }

        /// A 1 TB internal disk, a little under two thirds full.
        func volume() -> StorageInventory.Volume? {
            StorageInventory.Volume(
                name: "Macintosh HD", capacity: 994_662_584_320, available: 382_662_584_320,
            )
        }

        /// The bottle's own library, and one on an exFAT drive, which is the
        /// state the pane has to warn about.
        func libraries() -> [StorageInventory.Library] {
            guard scenario != .empty else { return [] }
            return [
                .init(
                    id: URL(fileURLWithPath: "/demo/Bottles/Steam/drive_c/Program Files (x86)/Steam"),
                    isInsideBottle: true, fileSystem: .mac, available: 382_662_584_320,
                    games: 3, bytes: 138_727_443_860,
                ),
                .init(
                    id: URL(fileURLWithPath: "/Volumes/Games/SteamLibrary"),
                    isInsideBottle: false, fileSystem: .foreign("exFAT"), available: 1_204_862_000_000,
                    games: 1, bytes: 71_940_702_208,
                ),
            ]
        }

        func installedGames() -> [StorageInventory.Game] {
            guard scenario != .empty else { return [] }
            return [
                .init(id: 1_245_620, name: "ELDEN RING", bytes: 62_277_025_792),
                .init(id: 2_050_650, name: "Resident Evil 4", bytes: 71_940_702_208),
                .init(id: 1_868_140, name: "DAVE THE DIVER", bytes: 4_509_715_660),
                .init(id: 892_970, name: "Valheim", bytes: 1_395_864_371),
            ].sorted { $0.bytes > $1.bytes }
        }

        func size(of entry: StorageInventory.Entry) async -> Int64 {
            try? await Task.sleep(
                for: scenario == .measuringSlowly ? .seconds(2) : .milliseconds(120),
            )
            return sizes[entry.id] ?? 0
        }

        func trash(_ entry: StorageInventory.Entry) throws {
            sizes[entry.id] = 0
            log("would move \(entry.name.lowercased()) to the Trash")
        }

        // MARK: - Added Windows programs

        func addedPrograms() -> [StorageInventory.Program] {
            guard scenario != .empty else { return [] }
            return Self.programs.filter { !removedPrograms.contains($0.id) }
        }

        func size(of program: StorageInventory.Program) async -> Int64 {
            try? await Task.sleep(for: .milliseconds(80))
            return program.installedRoot == nil ? 0 : program.bytes
        }

        func remove(program: StorageInventory.Program) throws {
            removedPrograms.insert(program.id)
            log("would forget \(program.name) and trash what its installer wrote")
        }

        /// One program installed into the bottle and one run from a folder of
        /// the user's own, which are the two rows this list has to draw.
        private static let programs: [StorageInventory.Program] = [
            .init(
                id: AdoptedPrograms.firstID, name: "Fate/stay night",
                path: "/demo/Bottles/Steam/drive_c/Program Files (x86)/Fate/fsn.exe",
                installedRoot: URL(
                    fileURLWithPath: "/demo/Bottles/Steam/drive_c/Program Files (x86)/Fate",
                ),
                bytes: 6_871_947_674,
            ),
            .init(
                id: AdoptedPrograms.firstID + 1, name: "RPG Maker MV",
                path: "/demo/Games/RPG Maker MV/rpgmv.exe",
                installedRoot: nil, bytes: 0,
            ),
        ]

        // MARK: - Shared game files

        func linkable() -> [SharedGames.Candidate] {
            guard scenario == .linkableGames else { return candidates }
            guard candidates.isEmpty else { return candidates }
            candidates = [
                Self.candidate(2_369_390, "Baldur's Gate 3", "BG3", 154_618_822_656),
                Self.candidate(1_593_500, "God of War", "GodOfWar", 74_088_284_160),
                Self.candidate(1_174_180, "Red Dead Redemption 2", "RDR2", 128_849_018_880),
            ]
            return candidates
        }

        private static func candidate(
            _ appID: Int, _ name: String, _ installdir: String, _ bytes: Int64,
        ) -> SharedGames.Candidate {
            SharedGames.Candidate(
                appID: appID,
                name: name,
                installdir: installdir,
                sourceSteamapps: URL(fileURLWithPath: "/demo/Bottles/Steam Beta/steamapps"),
                sourceBottle: "Steam Beta",
                sourceEngine: "CrossOver",
                bytes: bytes,
            )
        }

        func isLinked(appID: Int) -> Bool {
            linked.contains(appID)
        }

        func linkGameFiles(_ candidate: SharedGames.Candidate) throws {
            log("would link \(candidate.name)'s files from \(candidate.sourceBottle)")
            candidates.removeAll { $0.appID == candidate.appID }
        }

        func writeManifest(_ candidate: SharedGames.Candidate) throws {
            linked.insert(candidate.appID)
            log("would write \(candidate.name)'s manifest into this bottle")
        }

        func removePendingLink(_ candidate: SharedGames.Candidate) throws {
            candidates.append(candidate)
            log("would back the pending link for \(candidate.name) out")
        }

        func unlink(appID: Int) throws {
            linked.remove(appID)
            log("would remove the link for app \(appID)")
        }

        // MARK: - Uninstall

        func stopEverything(supervisor _: ClientSupervisor?) async {
            log("would stand supervision down and stop every process in the bottle")
            try? await Task.sleep(for: .seconds(1))
        }

        func trashBottle() throws {
            sizes = sizes.mapValues { _ in 0 }
            log("would move the whole bottle to the Trash")
        }

        func trashAppCaches() {
            log("would move this app's web session and caches to the Trash")
        }

        func removeAgentIntegration() async {
            log("would remove the CLI and the MCP entries agents were given")
        }

        func forgetSettings() {
            log("would reset this app's own preferences")
        }

        func trashAppBundle() {
            log("would move Sevoflurane.app itself to the Trash — the last step")
        }

        private func log(_ message: String) {
            EventLog.shared.log(.setup, "demo: storage: \(message)")
        }
    }
#endif
