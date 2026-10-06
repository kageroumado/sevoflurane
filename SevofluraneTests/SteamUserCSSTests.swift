import Foundation
import JavaScriptCore
import Testing
@testable import Sevoflurane

/// The custom style's page script, run against a one-head stand-in for the
/// DOM: what it carries, where its element sits, and what a second
/// evaluation or the removal does.
struct SteamUserCSSTests {
    private static let hostileCSS = "a::after { content: \"</style><script>alert('x')</script><!-- \\\\ \u{2028}\" }\n"

    /// A head that keeps its children in order, the element lookups the
    /// script makes, and observers fired by hand.
    private static let dom = """
    var window = this;
    function El(tag) { this.tagName = tag; this.id = ""; this.textContent = ""; this.parent = null; }
    El.prototype.remove = function () {
      if (this.parent) { this.parent.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; }
    };
    var head = {
      children: [],
      appendChild: function (el) { el.remove(); this.children.push(el); el.parent = this; },
      get lastElementChild() { return this.children[this.children.length - 1] || null; }
    };
    var document = {
      head: head,
      getElementById: function (id) { return head.children.find(function (el) { return el.id === id; }) || null; },
      createElement: function (tag) { return new El(tag); }
    };
    var observers = [];
    function MutationObserver(callback) { this.callback = callback; observers.push(this); }
    MutationObserver.prototype.observe = function () {};
    function mutate() { observers.forEach(function (o) { o.callback(); }); }
    function styles() { return head.children.filter(function (el) { return el.id === "sevo-user-css"; }); }
    """

    private func page() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript(Self.dom)
        try #require(context.exception == nil)
        return context
    }

    private func run(_ script: String, in context: JSContext) -> String? {
        let result = context.evaluateScript(script)?.toString()
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return result
    }

    @Test
    func `the stylesheet cannot end or reshape a script or style element`() {
        let script = SteamUserCSS.script(css: Self.hostileCSS)
        #expect(!script.contains("</style"))
        #expect(!script.contains("</script"))
        #expect(!script.contains("<!--"))
    }

    @Test
    func `a hostile stylesheet lands on the page as written`() throws {
        let context = try page()
        #expect(run(SteamUserCSS.script(css: Self.hostileCSS), in: context) == "installed")
        #expect(run("styles().length", in: context) == "1")
        #expect(run("styles()[0].textContent", in: context) == Self.hostileCSS)
    }

    @Test
    func `a second evaluation replaces the stylesheet in place`() throws {
        let context = try page()
        _ = run(SteamUserCSS.script(css: "a { color: red }"), in: context)
        #expect(run(SteamUserCSS.script(css: "a { color: blue }"), in: context) == "updated")
        #expect(run("styles().length", in: context) == "1")
        #expect(run("styles()[0].textContent", in: context) == "a { color: blue }")
        #expect(run("observers.length", in: context) == "1")
    }

    @Test
    func `the style moves back to the end when Steam adds a stylesheet after it`() throws {
        let context = try page()
        _ = run(SteamUserCSS.script(css: "a { color: red }"), in: context)
        _ = run("head.appendChild(document.createElement('link')); mutate()", in: context)
        #expect(run("head.lastElementChild.id", in: context) == SteamUserCSS.styleID)
        #expect(run("head.children.length", in: context) == "2")
    }

    @Test
    func `removal takes the style off and keeps it off`() throws {
        let context = try page()
        _ = run(SteamUserCSS.script(css: "a { color: red }"), in: context)
        #expect(run(SteamUserCSS.removalScript, in: context) == "removed")
        _ = run("head.appendChild(document.createElement('link')); mutate()", in: context)
        #expect(run("styles().length", in: context) == "0")
        _ = run(SteamUserCSS.script(css: "a { color: green }"), in: context)
        #expect(run("styles()[0].textContent", in: context) == "a { color: green }")
        #expect(run("head.lastElementChild.id", in: context) == SteamUserCSS.styleID)
    }

    @Test
    func `removal on a page that never had the style does nothing`() throws {
        let context = try page()
        #expect(run(SteamUserCSS.removalScript, in: context) == "not installed")
    }
}

/// The Styles folder: which files make the stylesheet, in what order, and
/// the sample it starts with.
struct UserStylesTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "styles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test
    func `stylesheets join in Finder's name order`() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, text) in [
            ("10-late.css", "late"), ("2-early.css", "early"), ("Z.CSS", "upper"),
            ("notes.txt", "text"), (".hidden.css", "hidden"),
        ] {
            try text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        #expect(UserStyles.stylesheet(in: folder) == "/* 2-early.css */\nearly\n/* 10-late.css */\nlate\n/* Z.CSS */\nupper")
    }

    @Test
    func `a missing folder is an empty stylesheet`() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "styles-\(UUID().uuidString)")
        #expect(UserStyles.stylesheet(in: missing).isEmpty)
    }

    @Test
    func `the folder starts with the sample and keeps the user's edits`() throws {
        let parent = try folder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let styles = parent.appending(path: "Styles")
        try UserStyles.prepareFolder(styles)
        let sample = styles.appending(path: UserStyles.sampleName)
        #expect(try String(contentsOf: sample, encoding: .utf8) == UserStyles.sample)
        try "edited".write(to: sample, atomically: true, encoding: .utf8)
        try UserStyles.prepareFolder(styles)
        #expect(try String(contentsOf: sample, encoding: .utf8) == "edited")
    }

    @Test
    func `the sample is one comment, so it styles nothing`() {
        let text = UserStyles.sample.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text.hasPrefix("/*"))
        #expect(text.hasSuffix("*/"))
        #expect(text.components(separatedBy: "*/").count == 2)
        #expect(text.components(separatedBy: "/*").count == 2)
    }
}
