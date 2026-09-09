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
}
