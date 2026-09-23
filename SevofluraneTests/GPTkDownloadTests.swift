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
}
