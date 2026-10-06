import Foundation
import Testing
@testable import Sevoflurane

/// What legendary and gogdl print, as Sevoflurane reads it: their JSON, the
/// progress lines a download logs, and the pages each store's login ends on.
/// The JSON is shaped as each tool's source at the pinned release writes it
/// (legendary 0.20.43 `cli.py`, gogdl 1.3.0 `auth.py` and `manager.py`).
struct StoreOutputTests {
    // MARK: - Progress

    @Test
    func `legendary's download line is a percentage`() {
        let line = "[DLManager] INFO: = Progress: 42.50% (850/2000), Running for 00:01:10, ETA: 00:01:35"
        #expect(StoreOutput.progress(line) == StoreProgress(phase: .downloading, fraction: 0.425))
    }

    @Test
    func `legendary's check line is a percentage of files`() {
        let line = "Verification progress: 12/345 (3.5%) [10.0 MiB/s]\t"
        #expect(StoreOutput.progress(line) == StoreProgress(phase: .checking, fraction: 0.035))
    }

    @Test
    func `gogdl's line names bytes written and bytes in all`() {
        let line = "[PROGRESS] INFO: = Progress: 25.00 250000/1000000, Running for: 00:00:04, ETA: 00:00:12"
        let progress = StoreOutput.progress(line)
        #expect(progress?.fraction == 0.25)
        #expect(progress?.bytesDone == 250_000)
        #expect(progress?.bytesTotal == 1_000_000)
    }

    @Test
    func `other log lines are not progress`() {
        #expect(StoreOutput.progress("[DLManager] INFO:  - Downloaded: 12.00 MiB, Written: 40.00 MiB") == nil)
        #expect(StoreOutput.progress("[cli] INFO: Install size: 1234.56 MiB") == nil)
    }

    @Test
    func `legendary announces the download size in mebibytes`() {
        let line = "[cli] INFO: Download size: 2.00 MiB (Compression savings: 50.0%)"
        #expect(StoreOutput.legendaryDownloadSize(line) == 2_097_152)
        #expect(StoreOutput.legendaryDownloadSize("[cli] INFO: Install size: 4.00 MiB") == nil)
    }

    @Test
    func `a failure reads as the client's last error line`() {
        let result = StoreProcess.Result(
            status: 1, stdout: "",
            stderr: "[cli] INFO: Logging in...\n[cli] ERROR: Game is out of date\n[cli] INFO: bye\n",
        )
        #expect(result.failure == "Game is out of date")
    }

    @Test
    func `argument strings split on spaces outside quotes`() {
        #expect(StoreOutput.splitArguments(#"-skipintro "-config C:\a b\x.ini" /fast"#)
            == ["-skipintro", #"-config C:\a b\x.ini"#, "/fast"])
        #expect(StoreOutput.splitArguments("  ") == [])
    }

    // MARK: - Epic

    @Test
    func `the login ends on a page holding the code`() throws {
        let page = try #require(URL(string: "https://www.epicgames.com/id/api/redirect?clientId=x&responseType=code"))
        #expect(Legendary.isRedirectPage(page))
        #expect(!Legendary.isRedirectPage(Legendary.loginURL))
        let text = #"{"warning":"Do not share this code","redirectUrl":"https://localhost/launcher/authorized?code=abc","authorizationCode":"abc123","sid":null}"#
        #expect(Legendary.authorizationCode(inPage: text) == "abc123")
        #expect(Legendary.authorizationCode(inPage: #"{"authorizationCode":null}"#) == nil)
    }

    @Test
    func `status names the account or no one`() {
        #expect(Legendary.account(inStatus: #"{"account":"kiri","games_available":3,"games_installed":0,"egl_sync_enabled":false,"config_directory":"/x"}"#) == "kiri")
        #expect(Legendary.account(inStatus: #"{"account":"<not logged in>","games_available":0}"#) == nil)
    }

    @Test
    func `the library keeps installable Windows games`() {
        let titles = Legendary.titles(inList: Self.epicList)
        #expect(titles.map(\.id) == ["Fortress", "Owl"])
        #expect(titles.first?.title == "A Fortress")
        #expect(titles.first?.version == "1.2.0")
        #expect(titles.first?.art?.absoluteString == "https://cdn1.epicgames.com/box.jpg")
        #expect(titles.last?.art?.absoluteString == "https://cdn1.epicgames.com/tall.jpg")
    }

    @Test
    func `installed games leave out DLC`() {
        let text = """
        [{"app_name":"Owl","title":"Owl Story","version":"7","install_path":"/b/drive_c/Program Files/Epic Games/Owl",
          "install_size":1048576,"is_dlc":false,"platform":"Windows","executable":"Owl.exe"},
         {"app_name":"OwlDLC","title":"Owl Extra","version":"1","install_path":"/b/x","is_dlc":true,"platform":"Windows"}]
        """
        let installs = Legendary.installs(inList: text)
        #expect(installs == [StoreInstall(
            store: .epic, id: "Owl", title: "Owl Story", path: "/b/drive_c/Program Files/Epic Games/Owl",
            version: "7", size: 1_048_576,
        )])
    }

    @Test
    func `info names the manifest's disk size`() {
        let text = #"{"game":{"app_name":"Owl"},"install":null,"manifest":{"disk_size":5000,"download_size":2000}}"#
        #expect(Legendary.diskSize(inInfo: text) == 5000)
        #expect(Legendary.diskSize(inInfo: #"{"game":{},"manifest":null}"#) == nil)
    }

    @Test
    func `a launch is the game's arguments then Epic's, ownership token on the Z drive`() {
        let text = """
        {"game_parameters":["\\"-flag value\\"","-nosplash"],"game_executable":"Binaries/Win64/Owl.exe",
         "game_directory":"/Games/Owl","egl_parameters":["-AUTH_LOGIN=unused","-AUTH_PASSWORD=code1",
         "-AUTH_TYPE=exchangecode","-epicapp=Owl","-epicovt=/Users/k/legendary/tmp/ns.ovt"],
         "launch_command":[],"working_directory":"/Games/Owl/Binaries/Win64","user_parameters":[],
         "environment":{},"pre_launch_command":"","pre_launch_wait":false}
        """
        let plan = Legendary.launchPlan(inJSON: text)
        #expect(plan?.folder == "/Games/Owl")
        #expect(plan?.executable == "/Games/Owl/Binaries/Win64/Owl.exe")
        #expect(plan?.workingDirectory == "/Games/Owl/Binaries/Win64")
        #expect(plan?.arguments == [
            "-flag value", "-nosplash", "-AUTH_LOGIN=unused", "-AUTH_PASSWORD=code1",
            "-AUTH_TYPE=exchangecode", "-epicapp=Owl", #"-epicovt=Z:\Users\k\legendary\tmp\ns.ovt"#,
        ])
    }

    // MARK: - GOG

    @Test
    func `the GOG login ends on a page with the code in its query`() throws {
        let done = try #require(URL(string: "https://embed.gog.com/on_login_success?origin=client&code=xyz"))
        #expect(GOG.authorizationCode(in: done) == "xyz")
        #expect(GOG.authorizationCode(in: GOG.loginURL) == nil)
    }

    @Test
    func `auth prints tokens, or null when signed out`() {
        let text = #"{"expires_in":3600,"access_token":"tok","user_id":"4801","refresh_token":"r","session_id":"s","loginTime":1.0}"#
        #expect(GOG.credentials(inAuth: text) == GOG.Credentials(accessToken: "tok", userID: "4801"))
        #expect(GOG.credentials(inAuth: "null") == nil)
        #expect(GOG.credentials(inAuth: #"{"error": true}"#) == nil)
    }

    @Test
    func `a library page keeps games that run on Windows`() throws {
        let text = """
        {"page":1,"totalPages":3,"products":[
          {"id":1207658924,"title":"Unreal Gold","image":"//images-1.gog-statics.com/abc","isGame":true,
           "worksOn":{"Windows":true,"Mac":false,"Linux":false}},
          {"id":2,"title":"A Mac Game","image":"//images-1.gog-statics.com/def","isGame":true,
           "worksOn":{"Windows":false,"Mac":true,"Linux":false}},
          {"id":3,"title":"A Soundtrack","image":"","isGame":false,"worksOn":{"Windows":true}}]}
        """
        let page = try #require(GOG.libraryPage(Data(text.utf8)))
        #expect(page.pages == 3)
        #expect(page.titles == [StoreTitle(
            store: .gog, id: "1207658924", title: "Unreal Gold",
            art: URL(string: "https://images-1.gog-statics.com/abc_196.jpg"),
        )])
    }

    @Test
    func `info is the build and the size of shared files plus English`() {
        let text = """
        {"size":{"*":{"download_size":10,"disk_size":100},"en-US":{"download_size":5,"disk_size":50},
         "de-DE":{"download_size":5,"disk_size":70}},"dlcs":[],"buildId":"5843","languages":["en-US"],
         "folder_name":"Unreal Gold","dependencies":[],"versionEtag":"x","versionName":"2.2","available_branches":[null]}
        """
        #expect(GOG.build(inInfo: text) == GOG.Build(id: "5843", name: "2.2", folder: "Unreal Gold", size: 150))
    }

    @Test
    func `the primary play task starts the game`() {
        let text = """
        {"gameId":"1207658924","rootGameId":"1207658924","name":"Unreal Gold","playTasks":[
          {"category":"tool","path":"Manual.pdf","type":"FileTask"},
          {"category":"game","isPrimary":true,"path":"System\\\\Unreal.exe","workingDir":"System",
           "arguments":"-nohomedir \\"-ini=My Config.ini\\"","type":"FileTask"}]}
        """
        let folder = URL(fileURLWithPath: "/Games/Unreal Gold")
        let plan = GOG.launchPlan(inInfo: text, folder: folder)
        #expect(plan == StoreLaunchPlan(
            folder: "/Games/Unreal Gold",
            executable: "/Games/Unreal Gold/System/Unreal.exe",
            workingDirectory: "/Games/Unreal Gold/System",
            arguments: ["-nohomedir", "-ini=My Config.ini"],
        ))
    }

    // MARK: - Launching

    @Test
    func `a working folder other than the executable's becomes start's slash d`() {
        let program = AdoptedProgram(
            path: "/Games/Owl/Owl.exe", arguments: ["-x"], bottle: "Steam", kind: ProgramKind.game,
            addedAt: .now, workingDirectory: "/Games/Owl/Data",
        )
        #expect(AdoptedPrograms.invocation(program)
            == ["start", "/d", #"Z:\Games\Owl\Data"#, "/unix", "/Games/Owl/Owl.exe", "-x"])
    }

    private static let epicList = """
    [{"metadata":{"keyImages":[{"type":"DieselGameBoxTall","url":"https://cdn1.epicgames.com/tall.jpg"},
       {"type":"DieselGameBox","url":"https://cdn1.epicgames.com/box.jpg"}],"customAttributes":{}},
      "asset_infos":{"Windows":{"app_name":"Fortress","build_version":"1.2.0","namespace":"ns"}},
      "app_name":"Fortress","app_title":"A Fortress","base_urls":[],"sidecar":null,"dlcs":[]},
     {"metadata":{"keyImages":[{"type":"DieselGameBoxTall","url":"https://cdn1.epicgames.com/tall.jpg"}]},
      "asset_infos":{"Windows":{"build_version":"7"}},"app_name":"Owl","app_title":"Owl Story","dlcs":[]},
     {"metadata":{"customAttributes":{"ThirdPartyManagedApp":{"type":"STRING","value":"the EA app"}}},
      "asset_infos":{"Windows":{"build_version":"1"}},"app_name":"Origin1","app_title":"EA Game","dlcs":[]},
     {"metadata":{},"asset_infos":{"Mac":{"build_version":"1"}},"app_name":"MacOnly","app_title":"Mac Only","dlcs":[]}]
    """
}
