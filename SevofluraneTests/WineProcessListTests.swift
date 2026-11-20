import Foundation
import Testing
@testable import Sevoflurane

/// Reading Windows programs out of `pgrep -lf`: the pid, then argv[0] as a
/// Windows path that may hold spaces.
struct WineProcessListTests {
    private let output = """
    96374 C:\\Program Files (x86)\\Steam\\Steam.exe -silent -nocrashdialog WINEESYNC=1
    96375 /Users/k/Engines/r16/sevo-discord-bridge.exe --dir /tmp/ WINEMSYNC=1
    11144 start.exe /exec cmd /c
    20001 D:\\Games\\MyGame\\MyGame.EXE -windowed
    20002 D:\\Games\\Game\\game.exe
    20003 D:\\Tools\\c++.exe --version
    not-a-pid something.exe
    """

    @Test
    func `parses pgrep long output`() {
        let entries = WineProcessList.entries(fromPgrepLong: output)
        #expect(entries.map(\.pid) == [96374, 96375, 11144, 20001, 20002, 20003])
        #expect(entries.map(\.name) == [
            "steam.exe", "sevo-discord-bridge.exe", "start.exe", "mygame.exe", "game.exe", "c++.exe",
        ])
        #expect(entries[0].path == "c:/program files (x86)/steam/steam.exe")
    }

    /// Two RPG Maker games both run `game.exe`; the folder its path runs
    /// through says whose it is. A bare name cannot be placed and stays a match.
    @Test
    func `a process is placed in a game folder by its path`() {
        let listing = """
        30001 C:\\Program Files (x86)\\Steam\\steamapps\\common\\OMORI\\www\\..\\Game.exe
        30002 C:\\Program Files (x86)\\Steam\\steamapps\\common\\Demons Roots\\Game.exe
        30003 game.exe
        """
        let entries = WineProcessList.entries(fromPgrepLong: listing)
        #expect(entries.filter { $0.lies(inFolderNamed: "Demons Roots") }.map(\.pid) == [30002, 30003])
        #expect(entries.filter { $0.lies(inFolderNamed: "omori") }.map(\.pid) == [30001, 30003])
    }

    @Test
    func `names are matched exactly`() {
        #expect(WineProcessList.pids(named: "game.exe", inPgrepLong: output) == [20002])
        #expect(WineProcessList.pids(named: "MyGame.exe", inPgrepLong: output) == [20001])
        #expect(WineProcessList.pids(named: "c++.exe", inPgrepLong: output) == [20003])
        #expect(WineProcessList.pids(named: "Game", inPgrepLong: output).isEmpty)
    }

    @Test
    func `a program kept outside the bottle is found by its own path`() {
        let listing = """
        501 Z:\\Volumes\\Games\\Tools\\Hang.exe idle
        502 Z:\\Volumes\\Games\\Other\\hang.exe
        503 C:\\Program Files (x86)\\Steam\\steam.exe -silent
        """
        let entries = WineProcessList.entries(fromPgrepLong: listing)
        #expect(GameEnding.processes(startedFrom: "/Volumes/Games/Tools/hang.exe", in: entries) == [501])
        #expect(GameEnding.processes(startedFrom: "/Volumes/Games/Missing/hang.exe", in: entries).isEmpty)
    }
}
