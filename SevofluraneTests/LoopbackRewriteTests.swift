import Foundation
import Testing
@testable import Sevoflurane

/// What the serve-time rewrite does to the bundle's own references to
/// `https://steamloopback.host`. The two outcomes look alike in the source and
/// behave nothing alike in the page: an origin that no longer matches makes
/// `postMessage` a silent no-op, and a URL that keeps the bare origin misses
/// the route that answers it.
struct LoopbackRewriteTests {
    @Test
    func `an origin comparison becomes this server's own origin`() {
        let source = #"k(e,"https://steamloopback.host")?"https://steamloopback.host":""#
        let origin = LoopbackAssets.pageOrigin
        let rewritten = LoopbackAssets.rewritten(source)
        #expect(rewritten == #"k(e,"\#(origin)")?"\#(origin)":""#)
        #expect(!rewritten.contains(LoopbackAssets.pathPrefix))
    }

    @Test
    func `a post message target origin keeps matching the page`() {
        let source = #"window.parent.postMessage(e,"https://steamloopback.host")"#
        #expect(
            LoopbackAssets.rewritten(source)
                == #"window.parent.postMessage(e,"\#(LoopbackAssets.pageOrigin)")"#,
        )
    }

    @Test
    func `a url moves under the loopback route`() {
        let prefix = LoopbackAssets.pageOrigin + LoopbackAssets.pathPrefix
        #expect(
            LoopbackAssets.rewritten(#"src:`https://steamloopback.host/windows/icon?handle=${t}`"#)
                == #"src:`\#(prefix)/windows/icon?handle=${t}`"#,
        )
        #expect(
            LoopbackAssets.rewritten(#"return"https://steamloopback.host/"+e"#)
                == #"return"\#(prefix)/"+e"#,
        )
    }

    @Test
    func `a url built from an interpolated path keeps the route`() {
        // `BuildCachedLibraryAssetURL` returns a rooted path, so the literal
        // ends at the host with no slash of its own — and is still a URL.
        let prefix = LoopbackAssets.pageOrigin + LoopbackAssets.pathPrefix
        #expect(
            LoopbackAssets.rewritten(#"`https://steamloopback.host${a.B7.Build(e)}`"#)
                == #"`\#(prefix)${a.B7.Build(e)}`"#,
        )
    }

    @Test
    func `text without the client origin is returned unchanged`() {
        let source = "export const host = \"https://store.steampowered.com\";"
        #expect(LoopbackAssets.rewritten(source) == source)
    }

    @Test
    func `the account's files are withheld from the loopback route`() {
        #expect(!LoopbackAssets.isServable("/config/config.vdf"))
        #expect(!LoopbackAssets.isServable("/config/loginusers.vdf"))
        #expect(!LoopbackAssets.isServable("/ssfn123"))
        #expect(!LoopbackAssets.isServable("/registry.vdf"))
        #expect(!LoopbackAssets.isServable("/userdata/1234/config/localconfig.vdf"))
        #expect(!LoopbackAssets.isServable("/logs/connection_log.txt"))
    }

    @Test
    func `the withheld files stay withheld however the path is spelled`() {
        #expect(!LoopbackAssets.isServable("/CONFIG/config.vdf"))
        #expect(!LoopbackAssets.isServable("/%63onfig/config.vdf"))
        #expect(!LoopbackAssets.isServable("/public/../config/config.vdf"))
        #expect(!LoopbackAssets.isServable("/public/%2E%2E/ssfn123"))
        #expect(!LoopbackAssets.isServable("//ssfn123"))
    }

    @Test
    func `the UI's assets are served`() {
        #expect(LoopbackAssets.isServable("/public/images/avatar.png"))
        #expect(LoopbackAssets.isServable("/steamui/css/library.css"))
        #expect(LoopbackAssets.isServable("/assets/12345/header.jpg"))
    }

    @Test
    func `the rewrite cache tells same-named files in different directories apart`() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let steamui = LoopbackAssets.cacheKey(path: "/steam/steamui/main.js", size: 10, modified: date)
        let tenfoot = LoopbackAssets.cacheKey(path: "/steam/tenfoot/main.js", size: 10, modified: date)
        #expect(steamui.family != tenfoot.family)
        #expect(steamui.name != tenfoot.name)
        #expect(steamui.name.hasPrefix(steamui.family))
    }

    @Test
    func `one file's cache family is never the prefix of another's`() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let chunk = LoopbackAssets.cacheKey(path: "/steam/steamui/chunk.js", size: 1, modified: date)
        let numbered = LoopbackAssets.cacheKey(path: "/steam/steamui/chunk-123.js", size: 1, modified: date)
        #expect(!numbered.name.hasPrefix(chunk.family))
        #expect(!chunk.name.hasPrefix(numbered.family))
    }
}
