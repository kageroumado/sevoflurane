import Foundation
import Testing
@testable import Sevoflurane

/// What the in-app toolkit download accepts from Apple's page.
struct GPTkDownloadTests {
    @Test
    func `the version is read from filenames with spaces or underscores`() {
        #expect(GPTkDownload.version(inFilename: "Evaluation_environment_for_Windows_games_4.0_beta_2.dmg") == "4.0 beta 2")
        #expect(GPTkDownload.version(inFilename: "Evaluation environment for Windows games 4.0 beta 2.dmg") == "4.0 beta 2")
        #expect(GPTkDownload.version(inFilename: "Game_Porting_Toolkit_3.0.dmg") == "3.0")
        #expect(GPTkDownload.version(inFilename: "Game_Porting_Toolkit.dmg") == nil)
    }

    @Test
    func `only Apple's download host over HTTPS is fetched`() throws {
        let apple = try #require(URL(string: "https://download.developer.apple.com/Developer_Tools/x/Game_Porting_Toolkit_3.0.dmg"))
        #expect(GPTkDownload.isAppleDownload(apple))
        let plain = try #require(URL(string: "http://download.developer.apple.com/x.dmg"))
        #expect(!GPTkDownload.isAppleDownload(plain))
        let elsewhere = try #require(URL(string: "https://download.developer.apple.com.example.net/x.dmg"))
        #expect(!GPTkDownload.isAppleDownload(elsewhere))
        let credentials = try #require(URL(string: "https://a:b@download.developer.apple.com/x.dmg"))
        #expect(!GPTkDownload.isAppleDownload(credentials))
    }

    @Test(arguments: [
        "https://developer.apple.com/programs/enroll/",
        "https://developer.apple.com/enroll/",
        "https://developer.apple.com/enroll/app",
        "https://developer.apple.com/Programs/Enroll",
        "https://developer.apple.com/programs/enrollment/",
        "https://developer.apple.com/account/#/enroll",
    ])
    func `links into the paid program's enrollment are stopped`(link: String) throws {
        #expect(try GPTkDownload.isEnrollment(#require(URL(string: link))))
    }

    @Test(arguments: [
        "https://developer.apple.com/download/all/?q=game%20porting%20toolkit",
        "https://developer.apple.com/account/",
        "https://developer.apple.com/programs/",
        "https://download.developer.apple.com/Developer_Tools/x/Game_Porting_Toolkit_3.0.dmg",
        "https://idmsa.apple.com/IDMSWebAuth/signin",
        "https://www.apple.com/enroll/",
        "https://developer.apple.com/enrolled-devices/",
    ])
    func `the download page, sign-in and other hosts load`(link: String) throws {
        #expect(try !GPTkDownload.isEnrollment(#require(URL(string: link))))
    }

    @Test
    func `a pick's versions come from its links' filenames, each once`() {
        let versions = GPTkDownload.versions(inLinks: [
            "https://download.developer.apple.com/Developer_Tools/a/Evaluation_environment_for_Windows_games_4.0.dmg",
            "https://download.developer.apple.com/Developer_Tools/b/Evaluation_environment_for_Windows_games_4.0_beta_2.dmg",
            "https://download.developer.apple.com/Developer_Tools/c/Game_Porting_Toolkit_4.0.dmg",
            "https://download.developer.apple.com/Developer_Tools/d/Readme.dmg",
        ])
        #expect(versions == ["4.0", "4.0 beta 2"])
    }
}
