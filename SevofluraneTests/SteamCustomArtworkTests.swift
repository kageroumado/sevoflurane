import Foundation
import Testing
@testable import Sevoflurane

/// Which account's grid folder the bridge serves `/customimages/` from. A
/// wrong pick shows nothing at all: the library falls back to Steam's art.
struct SteamCustomArtworkTests {
    @Test
    func `the account marked MostRecent is the signed-in one`() {
        let text = """
        "users"
        {
        \t"76561197960265729"
        \t{
        \t\t"MostRecent"\t\t"0"
        \t\t"timestamp"\t\t"1900000000"
        \t}
        \t"76561198343010339"
        \t{
        \t\t"MostRecent"\t\t"1"
        \t\t"timestamp"\t\t"1700000000"
        \t}
        }
        """
        #expect(SteamBottle.signedInAccountID(loginUsers: text) == 382_744_611)
    }

    @Test
    func `without a mark the newest sign-in wins`() {
        let text = """
        "users"
        {
        \t"76561198343010339"
        \t{
        \t\t"timestamp"\t\t"1792306968"
        \t}
        \t"76561197960265729"
        \t{
        \t\t"timestamp"\t\t"1600000000"
        \t}
        }
        """
        #expect(SteamBottle.signedInAccountID(loginUsers: text) == 382_744_611)
    }

    @Test
    func `a file with no accounts names none`() {
        #expect(SteamBottle.signedInAccountID(loginUsers: "\"users\"\n{\n}\n") == nil)
        #expect(SteamBottle.signedInAccountID(loginUsers: "") == nil)
    }
}
