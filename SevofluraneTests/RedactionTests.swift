import Foundation
import Testing
@testable import Sevoflurane

/// What a report may not carry out of the machine it was written on.
struct RedactionTests {
    @Test
    func `a path under this Mac's home becomes a tilde`() {
        let line = "loading \(NSHomeDirectory())/Library/Logs/Sevoflurane.log"
        #expect(Redaction.apply(to: line) == "loading ~/Library/Logs/Sevoflurane.log")
    }

    @Test
    func `any account's home becomes a tilde, and the shared folder is left alone`() {
        #expect(
            Redaction.apply(to: "Mono path[0] = '/Users/someone/Games/data'")
                == "Mono path[0] = '~/Games/data'",
        )
        #expect(
            Redaction.apply(to: "/Users/Shared/CrossOver") == "/Users/Shared/CrossOver",
        )
    }

    @Test
    func `the Windows user is replaced on both sides of the translation`() {
        #expect(
            Redaction.apply(to: #"opening C:\users\someone\AppData\LocalLow\Team\Game"#)
                == #"opening C:\users\~\AppData\LocalLow\Team\Game"#,
        )
        #expect(
            Redaction.apply(to: "Bottles/Steam/drive_c/users/someone/Temp")
                == "Bottles/Steam/drive_c/users/~/Temp",
        )
    }

    @Test
    func `a Steam id is replaced and a number that is not one survives`() {
        #expect(
            Redaction.apply(to: "logged in as 76561198012345678")
                == "logged in as \(Redaction.steamID)",
        )
        #expect(Redaction.apply(to: "AppID 508440 exit code 1") == "AppID 508440 exit code 1")
    }

    @Test
    func `a persona a caller knows is replaced`() {
        #expect(
            Redaction.apply(to: "friend request from Kagerou", personas: ["Kagerou"])
                == "friend request from \(Redaction.persona)",
        )
    }

    @Test
    func `text with nothing to hide comes back unchanged`() {
        let line = "err:seh:NtRaiseException Unhandled exception code c0000005 flags 0 addr 0x140"
        #expect(Redaction.apply(to: line) == line)
    }
}
