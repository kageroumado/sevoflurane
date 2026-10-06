import Foundation
import JavaScriptCore
import Testing
@testable import Sevoflurane

/// The Streamer Mode script: what it carries from the settings, how, and when
/// it is injected at all.
struct StreamerMaskTests {
    private static let hostileName = "</script><script>alert(\"x\")</script><!-- \\ ' \n\u{2028}end"

    private func settings(isOn: Bool = true, name: String = "Player") -> StreamerMode.Settings {
        StreamerMode.Settings(
            isOn: isOn, displayName: name, avatarDataURI: Monogram.dataURI(for: name),
            knownNames: ["kirie_kagarino", name],
        )
    }

    @Test
    func `mode off injects nothing`() {
        let off = settings(isOn: false)
        #expect(StreamerMask.script(for: off) == nil)
        #expect(StreamerMask.headTag(for: off).isEmpty)
    }

    @Test
    func `mode on injects one script element`() {
        let tag = StreamerMask.headTag(for: settings())
        #expect(tag.hasPrefix("<script>(()=>{"))
        #expect(tag.hasSuffix("</script>"))
    }

    @Test
    func `a hostile name cannot end or reshape the script element`() {
        let tag = StreamerMask.headTag(for: settings(name: Self.hostileName))
        #expect(tag.components(separatedBy: "</script").count == 2)
        #expect(tag.components(separatedBy: "<script").count == 2)
        #expect(!tag.contains("<!--"))
    }

    @Test
    func `a hostile name survives as the same string in JavaScript`() throws {
        let context = try #require(JSContext())
        let value = context.evaluateScript("(\(JSLiteral.inlineString(Self.hostileName)))")
        #expect(context.exception == nil)
        #expect(value?.toString() == Self.hostileName)
    }

    @Test
    func `the script parses with a hostile name`() throws {
        let context = try #require(JSContext())
        let script = try #require(StreamerMask.script(for: settings(name: Self.hostileName)))
        context.setObject(script, forKeyedSubscript: "source" as NSString)
        context.evaluateScript("new Function(source)")
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
    }

    @Test
    func `the monogram color is deterministic`() {
        #expect(Monogram.color(of: "Claude") == Monogram.color(of: "Claude"))
        #expect(Monogram.hue(of: "Claude") == Self.fnv1aHue("Claude"))
        #expect(Monogram.hue(of: "ChatGPT") == Self.fnv1aHue("ChatGPT"))
        #expect(Monogram.dataURI(for: "Gemini") == Monogram.dataURI(for: "Gemini"))
    }

    @Test
    func `monogram letters`() {
        #expect(Monogram.letters(of: "Claude Opus") == "CO")
        #expect(Monogram.letters(of: "ChatGPT") == "CG")
        #expect(Monogram.letters(of: "o3") == "O3")
        #expect(Monogram.letters(of: "Player") == "P")
        #expect(Monogram.letters(of: "DeepSeek-R1") == "DR")
        #expect(Monogram.letters(of: "") == "?")
    }

    @Test
    func `the monogram escapes its letters`() {
        #expect(Monogram.svg(for: "<Bob").contains(">&lt;B</text>"))
    }

    @Test
    func `an empty display name falls back to the default`() {
        #expect(StreamerMode.resolvedName("  ") == StreamerMode.defaultDisplayName)
        #expect(StreamerMode.resolvedName(nil) == StreamerMode.defaultDisplayName)
        #expect(StreamerMode.resolvedName(" Sora ") == "Sora")
    }

    @Test
    func `a missing picture file gives the monogram`() {
        let missing = URL(fileURLWithPath: "/nonexistent/streamer.png")
        #expect(StreamerMode.avatarDataURI(name: "Sora", file: missing) == Monogram.dataURI(for: "Sora"))
    }

    /// The page's rule, restated: FNV-1a over UTF-16 code units, modulo 360.
    private static func fnv1aHue(_ name: String) -> Int {
        var hash: UInt64 = 2_166_136_261
        for unit in name.utf16 {
            hash = ((hash ^ UInt64(unit)) * 16_777_619) & 0xFFFF_FFFF
        }
        return Int(hash % 360)
    }
}
