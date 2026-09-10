import Foundation
import Testing
@testable import Sevoflurane

/// The record an adopted Windows program is: the id it gets, the file it
/// becomes, and the command line it launches through.
struct AdoptedProgramsTests {
    private static let fixture = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/fixture.exe")

    // MARK: - Ids

    @Test
    func `the adopted range starts above every Steam app id`() {
        // Steam's ids are assigned sequentially and the highest published is
        // seven digits; two billion leaves three orders of magnitude of room.
        #expect(AdoptedPrograms.firstID == 2_000_000_000)
        #expect(AdoptedPrograms.isAdopted(AdoptedPrograms.firstID))
        #expect(!AdoptedPrograms.isAdopted(1_245_620))
        #expect(!AdoptedPrograms.isAdopted(0))
    }

    @Test
    func `an empty store hands out the first id`() {
        #expect(AdoptedPrograms.nextID(after: []) == AdoptedPrograms.firstID)
    }

    @Test
    func `Steam app ids in the store do not move the allocation`() {
        #expect(AdoptedPrograms.nextID(after: [1_245_620, 892_970])
            == AdoptedPrograms.firstID)
    }

    @Test
    func `an id is never reused after a removal`() {
        let first = AdoptedPrograms.firstID
        #expect(AdoptedPrograms.nextID(after: [first, first + 1]) == first + 2)
        // The middle one is gone; the next program still takes a fresh id.
        #expect(AdoptedPrograms.nextID(after: [first, first + 2]) == first + 3)
    }

    // MARK: - The command line

    @Test
    func `a launch goes through start slash unix, so the exe's folder is the working directory`() {
        let program = AdoptedProgram(
            path: "/Users/someone/Games/Nightsong/Nightsong.exe",
            bottle: "Steam", kind: ProgramKind.game, addedAt: .now,
        )
        #expect(AdoptedPrograms.invocation(program)
            == ["start", "/unix", "/Users/someone/Games/Nightsong/Nightsong.exe"])
    }

    @Test
    func `a path with spaces stays one argument and is never quoted`() {
        let program = AdoptedProgram(
            path: "/Users/someone/My Games/Fate stay night/fsn.exe",
            arguments: ["--lang", "ja JP"],
            bottle: "Steam", kind: ProgramKind.game, addedAt: .now,
        )
        let argv = AdoptedPrograms.invocation(program)
        #expect(argv == [
            "start", "/unix", "/Users/someone/My Games/Fate stay night/fsn.exe",
            "--lang", "ja JP",
        ])
        #expect(!argv.contains { $0.contains("\"") })
    }

    // MARK: - The record

    @Test
    func `a program's suggested name comes from its version resource`() {
        #expect(AdoptedPrograms.suggestedName(for: Self.fixture) == "Sevoflurane Fixture")
    }

    @Test
    func `a program with no version resource is named after its file`() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "Nightsong-\(UUID().uuidString).exe")
        try Data("MZ".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AdoptedPrograms.suggestedName(for: url) == url
            .deletingPathExtension().lastPathComponent)
    }

    @Test
    func `the record survives the settings file it is written to`() throws {
        let values = ConfigValues(
            windows: .window,
            exes: ["nightsong.exe"],
            name: "Nightsong",
            program: AdoptedProgram(
                path: "/Users/someone/Games/Nightsong/Nightsong.exe",
                arguments: ["--windowed"],
                bottle: "Steam",
                kind: ProgramKind.game,
                addedAt: Date(timeIntervalSince1970: 1_757_000_000),
                installedRoot: "/bottle/drive_c/Program Files/Nightsong",
            ),
        )
        let encoded = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode(ConfigValues.self, from: encoded)
        #expect(decoded == values)
        #expect(decoded.program?.installedRoot == "/bottle/drive_c/Program Files/Nightsong")
    }

    @Test
    func `a settings file written before adopted programs still reads`() throws {
        let old = Data(#"{"name":"ELDEN RING","exes":["eldenring.exe"]}"#.utf8)
        let values = try JSONDecoder().decode(ConfigValues.self, from: old)
        #expect(values.name == "ELDEN RING")
        #expect(values.program == nil)
    }

    @Test
    func `adopting writes a game file the store reads back, and removing takes it away`() throws {
        let id = AdoptedPrograms.nextID()
        defer { AdoptedPrograms.remove(id) }
        let adopted = AdoptedPrograms.adopt(
            exe: Self.fixture, kind: ProgramKind.program, arguments: ["--quiet"],
            bottle: "Steam",
        )
        #expect(adopted == id)

        let entry = try #require(AdoptedPrograms.entry(adopted))
        #expect(entry.name == "Sevoflurane Fixture")
        #expect(entry.kind == ProgramKind.program)
        #expect(entry.program.arguments == ["--quiet"])
        // The exe list is what makes the materializer write an env file and
        // build the launcher bundle for it.
        #expect(GameConfig.game(adopted).exes == ["fixture.exe"])
        #expect(AdoptedPrograms.all().contains { $0.id == adopted })

        AdoptedPrograms.remove(adopted)
        #expect(AdoptedPrograms.entry(adopted) == nil)
        #expect(GameConfig.game(adopted) == .empty)
    }
}
