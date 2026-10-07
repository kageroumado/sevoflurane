import Foundation
import Testing
@testable import Sevoflurane

/// What a report may not carry out of the machine it was written on.
struct RedactionTests {
    @Test
    func `a path under this Mac's home becomes a tilde`() {
        let line = "loading \(UserHome.path)/Library/Logs/Sevoflurane.log"
        #expect(Redaction.apply(to: line) == "loading ~/Library/Logs/Sevoflurane.log")
    }

    @Test
    func `a game account's uid becomes a placeholder, in a short text and in a long one`() {
        let line = "PreLoadSWURL: https://sdk.hoyoverse.com/sw.html?game=hk4e&region=os_euro&uid=712345678&lang=en"
        let expected = "PreLoadSWURL: https://sdk.hoyoverse.com/sw.html?game=hk4e&region=os_euro&uid=<uid>&lang=en"
        #expect(Redaction.apply(to: line) == expected)
        #expect(Redaction.apply(to: "UID: 712345678") == "UID: <uid>")
        let filler = String(repeating: "frame presented\n", count: 8000)
        #expect(Redaction.apply(to: filler + line).hasSuffix(expected))
        #expect(Redaction.apply(to: "build 2.55.0.0, fluid=1") == "build 2.55.0.0, fluid=1")
    }

    @Test
    func `this Mac's name becomes a placeholder`() throws {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        try #require(gethostname(&buffer, buffer.count - 1) == 0)
        let name = String(cString: buffer)
        try #require(name.count > 2)
        #expect(Redaction.apply(to: "wineserver: host \(name) answered") == "wineserver: host <host> answered")
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

    /// Unreal writes `LogInit: User: <name>` with no path around it.
    @Test
    func `the account's short name is replaced where it stands alone`() {
        let name = NSUserName()
        #expect(name.count > 2, "this Mac's short name is too short to redact")
        #expect(
            Redaction.apply(to: "LogInit: User: \(name)")
                == "LogInit: User: \(Redaction.user)",
        )
    }

    @Test
    func `text with nothing to hide comes back unchanged`() {
        let line = "err:seh:NtRaiseException Unhandled exception code c0000005 flags 0 addr 0x140"
        #expect(Redaction.apply(to: line) == line)
    }

    @Test
    func `a long log is redacted on the lines that carry something and left alone elsewhere`() {
        let quiet = String(repeating: "0024:trace:seh:dispatch_exception code=c0000005\n", count: 4000)
        let text = quiet + "loading \(UserHome.path)/Library/x.dll for 76561198000000001\n" + quiet
        let redacted = Redaction.apply(to: text)
        #expect(!redacted.contains(UserHome.path))
        #expect(!redacted.contains("76561198000000001"))
        #expect(redacted.hasPrefix(quiet))
        #expect(redacted.hasSuffix(quiet))
    }
}
