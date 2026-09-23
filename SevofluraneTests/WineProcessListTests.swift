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
        #expect(entries == [
            .init(pid: 96374, name: "steam.exe"),
            .init(pid: 96375, name: "sevo-discord-bridge.exe"),
            .init(pid: 11144, name: "start.exe"),
            .init(pid: 20001, name: "mygame.exe"),
            .init(pid: 20002, name: "game.exe"),
            .init(pid: 20003, name: "c++.exe"),
        ])
    }

    @Test
    func `names are matched exactly`() {
        #expect(WineProcessList.pids(named: "game.exe", inPgrepLong: output) == [20002])
        #expect(WineProcessList.pids(named: "MyGame.exe", inPgrepLong: output) == [20001])
        #expect(WineProcessList.pids(named: "c++.exe", inPgrepLong: output) == [20003])
        #expect(WineProcessList.pids(named: "Game", inPgrepLong: output).isEmpty)
    }
}
