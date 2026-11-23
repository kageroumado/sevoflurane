import Foundation
import Testing
@testable import Sevoflurane

/// Holds the app's sources and ``SteamSurface`` together.
///
/// The injected JavaScript spells Steam's names out, in `.js` resources and
/// in Swift string literals. These tests read every such script and fail
/// when one names a Steam internal the catalog does not list, and when the
/// catalog lists one that no source names.
///
/// What the scan recognizes as Steam's: `SteamClient` paths, capitalized
/// methods and properties, Valve's `m_` and Hungarian names, snake-case
/// properties, objects read off `window`, class names in selectors and
/// markup, and `steam://` links. A camel-case property of Steam's
/// (`allApps`, `modals`) looks like the app's own code, so those are held
/// one way only: listed and unused fails, used and unlisted does not.
///
/// The page's resolver (``SteamPageResolver``) is held to the catalog's two
/// builds: its webpack class maps to ``SteamSurface/ClassGroup``, its
/// recipes to ``SteamSurface/classRecipes``, and the props it finds a
/// component by to the catalog's tokens.
struct SteamSurfaceDriftTests {
    // MARK: - SteamClient paths

    @Test
    func `every SteamClient path in the sources is a call the catalog lists`() {
        let calls = Set(SteamSurface.Call.allCases.map(\.path))
        let answered = ["SteamClient.Window", "SteamClient.BrowserView", "SteamClient.Browser"]
        var unlisted: Set<String> = []
        for unit in Sources.scripts {
            for match in unit.text.matches(of: #/SteamClient(?:\??\.[A-Za-z_]\w*)+/#) {
                let path = String(match.0).replacingOccurrences(of: "?", with: "")
                let known = calls.contains(path)
                    || calls.contains { $0.hasPrefix(path + ".") }
                    || answered.contains { path == $0 || path.hasPrefix($0 + ".") }
                    || path == "SteamClient" || Sources.accounted.contains(path)
                if !known { unlisted.insert("\(path) (\(unit.path))") }
            }
        }
        #expect(unlisted.isEmpty, "SteamClient paths SteamSurface.Call lacks: \(unlisted.sorted())")
    }

    @Test
    func `every SteamClient call in the sources passes the arguments the catalog records`() {
        var wrong: [String] = []
        for unit in Sources.scripts {
            let file = SteamUIBundle.File(path: unit.path, text: unit.text)
            for call in SteamSurface.Call.allCases {
                guard let passes = call.facts.passes else { continue }
                // The method's own name, so a call through an alias
                // (`installs.OpenInstallWizard(`) is held to the same count.
                let needle = "." + (call.path.split(separator: ".").last ?? "") + "("
                for offset in file.offsets(of: needle) {
                    guard let (arguments, _) = file.arguments(from: offset + needle.utf8.count) else {
                        wrong.append("\(call.path) in \(unit.path) does not close")
                        continue
                    }
                    if arguments.count != passes {
                        wrong.append("\(call.path) passes \(arguments.count) in \(unit.path), the catalog says \(passes)")
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong)")
    }

    @Test
    func `every call built from the catalog passes the arguments the catalog records`() {
        var wrong: [String] = []
        var built = 0
        for source in Sources.swift {
            let file = SteamUIBundle.File(path: source.path, text: source.text)
            for call in SteamSurface.Call.allCases {
                let needle = ".\(call).invocation("
                for offset in file.offsets(of: needle) {
                    built += 1
                    let count = file.arguments(from: offset + needle.utf8.count)?.list.count
                    if count != call.facts.passes {
                        wrong.append("\(call).invocation in \(source.path) passes \(count.map(String.init) ?? "?"), the catalog says \(call.facts.passes.map(String.init) ?? "none")")
                    }
                }
            }
        }
        #expect(built > 0)
        #expect(wrong.isEmpty, "\(wrong)")
    }

    // MARK: - Names

    @Test
    func `every method and property of Steam's the scripts name is in the catalog`() {
        var unlisted: Set<String> = []
        for unit in Sources.scripts {
            for name in Sources.steamNames(in: unit.text) where !Sources.accounted.contains(name) {
                unlisted.insert("\(name) (\(unit.path))")
            }
        }
        #expect(unlisted.isEmpty, "Steam names the catalog lacks: \(unlisted.sorted())")
    }

    @Test
    func `every object the scripts read off Steam's window is in the catalog`() {
        var unlisted: Set<String> = []
        for unit in Sources.scripts {
            for name in Sources.steamGlobals(in: unit.text) where !Sources.accounted.contains(name) {
                unlisted.insert("\(name) (\(unit.path))")
            }
        }
        #expect(unlisted.isEmpty, "globals of Steam's the catalog lacks: \(unlisted.sorted())")
    }

    @Test
    func `the scan tells Steam's names from the app's and the browser's`() {
        let script = """
        var d = app.m_VoiceChat.StartCall(o.strThing, o.display_status), n = nextIdle + list.length;
        if (window.voiceStore && ctx.__sevoCompat && window.document) g_PopupManager.m_mapPopups.forEach(visit);
        win.WebSocket = window.WebSocket; var x = [ME, ...ROSTER]; uiStore.currentAppFilter; opener.appStore;
        """
        #expect(Sources.steamNames(in: script) == ["m_VoiceChat", "StartCall", "strThing", "display_status", "m_mapPopups"])
        #expect(Sources.steamGlobals(in: script) == ["voiceStore", "g_PopupManager", "uiStore", "appStore"])
    }

    // MARK: - Classes and links

    @Test
    func `every class and id the scripts select is the app's own or in the catalog`() {
        var unlisted: Set<String> = []
        func check(_ name: String, _ unit: Sources.Unit) {
            guard !name.hasPrefix("sevo"), !Sources.accounted.contains(name), Int(name) == nil else { return }
            unlisted.insert("\(name) (\(unit.path))")
        }
        func checkSelector(_ selector: Substring, _ unit: Sources.Unit) {
            for match in selector.matches(of: #/[.#](-?[A-Za-z_][\w-]*)/#) { check(String(match.1), unit) }
            for match in selector.matches(of: #/\[[\w-]+[~|^$*]?=\\?["']?([\w-]+)/#) { check(String(match.1), unit) }
        }
        for unit in Sources.scripts where !Sources.ownPages.contains(unit.path) {
            for match in unit.text.matches(of: #/(?:querySelector(?:All)?|closest|matches)\(\s*(["'])(.*?)\1/#) {
                checkSelector(match.2, unit)
            }
            for match in unit.text.matches(of: #/classList\.(?:contains|add|remove|toggle)\(\s*["']([\w-]+)["']/#) {
                check(String(match.1), unit)
            }
            for match in unit.text.matches(of: #/getElementById\(\s*["']([\w-]+)/#) { check(String(match.1), unit) }
            // A style rule inside a JavaScript string: its selector is what precedes the brace.
            for literal in unit.text.matches(of: #/"((?:[^"\\\n]|\\.)*)"/#) {
                for rule in literal.1.matches(of: #/([^{}]+)\{[^{}]*\}/#) { checkSelector(rule.1, unit) }
            }
            for match in unit.text.matches(of: #/class=\\?["']([^"'\\]*)/#) {
                for name in match.1.split(separator: " ") { check(String(name), unit) }
            }
        }
        #expect(unlisted.isEmpty, "classes and ids of Steam's the catalog lacks: \(unlisted.sorted())")
    }

    @Test
    func `every steam link in the sources is in the catalog`() {
        let listed = SteamSurface.entries(of: .url).map(\.name).filter { $0.hasPrefix("steam://") }
        var unlisted: Set<String> = []
        for unit in Sources.literals {
            for match in unit.text.matches(of: #/steam:\/\/[\w\/.\-]*/#) {
                let link = String(match.0)
                if link != "steam://", !listed.contains(where: { link.hasPrefix($0) || $0.hasPrefix(link) }) {
                    unlisted.insert("\(link) (\(unit.path))")
                }
            }
        }
        #expect(unlisted.isEmpty, "steam:// links the catalog lacks: \(unlisted.sorted())")
    }

    // MARK: - The other direction

    @Test
    func `every catalog entry is named by a source`() {
        // An entry backed by a Swift name may be used through that name alone.
        var symbols: [String: String] = [:]
        for call in SteamSurface.Call.allCases { symbols[call.path] = "\(call)" }
        for call in SteamSurface.WindowCall.allCases { symbols[call.rawValue] = "\(call)" }
        for popup in SteamSurface.Popup.allCases { symbols[popup.rawValue] = "\(popup)" }
        for setting in SteamSurface.Setting.allCases { symbols[setting.rawValue] = "\(setting)" }
        symbols[SteamSurface.popupInstanceMarker] = "popupInstanceMarker"
        symbols[SteamSurface.rootMenuTitleSuffix] = "rootMenuTitleSuffix"
        symbols[SteamSurface.windowResizedMessage] = "windowResizedMessage"
        symbols[SteamSurface.loopbackHost] = "loopbackHost"
        symbols[SteamSurface.launchOptionRequest] = "launchOptionRequest"

        let text = Sources.literals.map(\.text).joined(separator: "\n")
        let haystack = SteamUIBundle.File(path: "literals", text: text)
        let code = SteamUIBundle.File(path: "swift", text: Sources.swift.map(\.text).joined(separator: "\n"))
        let dash: Set<UInt8> = [UInt8(ascii: "-")]
        var unused: [String] = []
        for entry in SteamSurface.catalog {
            for token in entry.tokens {
                let spelled = token.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" })
                    ? haystack.contains(token)
                    : !haystack.wordOffsets(of: token, extra: dash).isEmpty
                let named = symbols[token].map { code.containsMember($0) } ?? false
                // A call may be made through an alias of its namespace.
                let aliased = entry.kind == .call && token.split(separator: ".").last.map { haystack.contains(".\($0)(") } ?? false
                if !spelled, !named, !aliased { unused.append("\(entry.kind.rawValue) \(token)") }
            }
        }
        #expect(unused.isEmpty, "catalog entries no source names: \(unused)")
    }

    // MARK: - The two builds

    @Test @MainActor
    func `the resolver's webpack maps are the catalog's class groups`() {
        for group in SteamSurface.ClassGroup.allCases {
            let signature = group.signature.map { "\"\($0)\"" }.joined(separator: ", ")
            let line = "\(group.rawValue): { has: [\(signature)], limit: \(group.limit), needs: ["
            #expect(SteamPageResolver.source.contains(line), "\(group.rawValue)")
        }
    }

    @Test @MainActor
    func `the resolver carries every recipe and names the links bar's props`() {
        #expect(SteamPageResolver.source.contains("var RECIPES = " + SteamSurface.classRecipesLiteral + ";"))
        for prop in SteamSurface.linksBarProps {
            #expect(SteamPageResolver.source.contains("\"\(prop)\" in props"))
        }
        #expect(SteamPageResolver.source.contains(#"querySelectorAll('[role="link"]')"#))
    }

    @Test @MainActor
    func `every class the scripts read has a recipe, or only finds its webpack module`() {
        // Keys the scripts read as classes: named after a map (`classes.play.PlayButton`, `f.Filters`).
        let sources = [SteamNativeBuilds.script, SteamLibraryCompat.script, SteamCompatBadge.script]
        for group in SteamSurface.ClassGroup.allCases where group != .strip {
            let recipes = Set(SteamSurface.classRecipes.filter { $0.group == group }.map(\.key))
            for key in group.keys where !recipes.contains(key) {
                #expect(group.signature.contains(key), "\(group.rawValue).\(key) has no recipe")
                let read = sources.contains { $0.contains(".\(group.rawValue).\(key)") }
                #expect(!read, "the scripts read \(group.rawValue).\(key), which a build of ES modules cannot answer")
            }
            #expect(recipes.isSubset(of: group.keys))
        }
    }

    @Test @MainActor
    func `every prop the scripts find a component by is in the catalog`() {
        var unlisted: Set<String> = []
        for unit in Sources.scripts {
            for match in unit.text.matches(of: #/"([A-Za-z_]\w*)"\s+in\s+props/#) where !Sources.accounted.contains(String(match.1)) {
                unlisted.insert("\(match.1) (\(unit.path))")
            }
        }
        #expect(unlisted.isEmpty, "props of Steam's components the catalog lacks: \(unlisted.sorted())")
        #expect(Sources.scripts.contains { $0.text.contains("in props") })
    }

    // MARK: - What the shim answers

    @Test
    func `the shim's browser view has the methods the catalog lists`() throws {
        let shim = try #require(Sources.all.first { $0.path.hasSuffix("steamclient_shim.js") }).text
        let start = try #require(shim.range(of: "function makeNativeBrowserView("))
        let end = try #require(shim.range(of: "function makeIframeBrowserView("))
        let native = shim[start.upperBound ..< end.lowerBound]
        let methods = Set(native.matches(of: #/\b([A-Z][A-Za-z]+): function/#).map { String($0.1) })
        #expect(methods == Set(SteamSurface.browserViewMethods))
        let list = try #require(native.firstMatch(of: #/\[((?:\s*"[A-Za-z]+",?)+)\s*\]\.forEach/#))
        let noOps = Set(list.1.matches(of: #/"([A-Za-z]+)"/#).map { String($0.1) })
        #expect(noOps == Set(SteamSurface.browserViewNoOps))

        let namespaceStart = try #require(shim.range(of: "var browserViewNamespace = {"))
        let namespaceEnd = try #require(shim.range(of: "var nativeOpen"))
        let namespace = shim[namespaceStart.upperBound ..< namespaceEnd.lowerBound]
        let members = Set(namespace.matches(of: #/\b([A-Z][A-Za-z]+): function/#).map { String($0.1) })
        #expect(members == Set(SteamSurface.browserViewNamespace))
    }

    @Test
    func `a native browser view fires the events the catalog lists`() throws {
        let child = try #require(Sources.all.first { $0.path.hasSuffix("BrowserViewChild.swift") }).text
        let fired = Set(child.matches(of: #/fire\(\s*"([a-z-]+)"/#).map { String($0.1) })
        #expect(fired == Set(SteamSurface.browserViewEvents))
    }

    @Test
    func `the scan reads the sources`() {
        #expect(Sources.scripts.count > 60)
        #expect(Sources.scripts.contains { $0.path.hasSuffix("steamclient_shim.js") })
        #expect(Sources.scripts.contains { $0.text.contains("g_PopupManager.m_mapPopups") })
    }
}

// MARK: - Reading the sources

/// The app's sources, as text and as the JavaScript inside them.
private enum Sources {
    struct Unit {
        /// The file, from the repository's root.
        let path: String
        let text: String
    }

    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Every Swift and JavaScript source of the app, its helpers and `sevo`.
    /// The catalog's own files are left out: they name everything.
    static let all: [Unit] = {
        var units: [Unit] = []
        for folder in ["Core", "Sevo", "Sevoflurane", "SevofluraneDaemon", "Shared", "Supervision"] {
            let base = root.appendingPathComponent(folder)
            let paths = (try? FileManager.default.subpathsOfDirectory(atPath: base.path)) ?? []
            for path in paths.sorted() where path.hasSuffix(".swift") || path.hasSuffix(".js") {
                let name = (path as NSString).lastPathComponent
                guard !name.hasPrefix("SteamSurface"), !path.contains("/nwjs/"),
                      let text = try? String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
                else { continue }
                units.append(Unit(path: "\(folder)/\(path)", text: text))
            }
        }
        return units
    }()

    static let swift = all.filter { $0.path.hasSuffix(".swift") }

    /// Every JavaScript file, and every string literal of the Swift sources.
    static let literals: [Unit] = all.flatMap { source -> [Unit] in
        source.path.hasSuffix(".js")
            ? [source]
            : SwiftLiterals.strings(in: source.text).map { Unit(path: source.path, text: $0) }
    }

    /// The literals that read as JavaScript, their comments removed.
    static let scripts: [Unit] = literals.compactMap { unit in
        guard unit.path.hasSuffix(".js") || unit.text.contains(#/function\s*\(|=>|\b(?:window|document|SteamClient)\.[A-Za-z_]|\b(?:var|const|return)\s/#)
        else { return nil }
        return Unit(path: unit.path, text: withoutComments(unit.text))
    }

    static func withoutComments(_ script: String) -> String {
        script
            .replacing(#/\/\*[\s\S]*?\*\//#, with: " ")
            .replacing(#/(^|\s)\/\/[^\n]*/#, with: " ")
    }

    /// Every name the catalog accounts for: each entry's tokens, the links of
    /// each call's path, and the surfaces the app answers.
    static let accounted: Set<String> = {
        var names = Set(SteamSurface.catalog.flatMap(\.tokens))
        for call in SteamSurface.Call.allCases { names.formUnion(call.path.split(separator: ".").map(String.init)) }
        names.formUnion(["Window", "BrowserView", "Browser"])
        names.formUnion(SteamSurface.WindowCall.unanswered)
        return names
    }()

    /// The names in `script` that are Steam's by their shape: a capitalized
    /// method or property, one of Valve's `m_` or Hungarian names, a
    /// snake-case property. Each pattern spells its own boundaries: `\b` in
    /// a Swift regex follows Unicode word rules, under which `a.m_b` is one word.
    static func steamNames(in script: String) -> Set<String> {
        var names: Set<String> = []
        for match in script.matches(of: #/(?:^|[^.])\.([A-Z][A-Za-z0-9_]*)/#) where !capitalizedOwn.contains(String(match.1)) {
            names.insert(String(match.1))
        }
        for match in script.matches(of: #/(?:^|[^\w$])(m_\w+|(?:str|vec|rg|map|un|fl)[A-Z]\w*|[bne][A-Z][a-z]\w*)/#) {
            names.insert(String(match.1))
        }
        for match in script.matches(of: #/\.([a-z]+(?:_[a-z0-9]+)+)(?![\w$])/#) where !snakeOwn.contains(String(match.1)) {
            names.insert(String(match.1))
        }
        return names.filter { !$0.hasPrefix("__sevo") }
    }

    /// The objects `script` reads off Steam's window: a property of
    /// `window`, `ctx` or `opener` that no browser has, and a bare `g_…`,
    /// `…Store` or `App`.
    static func steamGlobals(in script: String) -> Set<String> {
        var names: Set<String> = []
        for match in script.matches(of: #/(?:^|[^\w$])(?:window|ctx|opener)\??\.([A-Za-z_$][\w$]*)/#) {
            let name = String(match.1)
            if !browserGlobals.contains(name), !name.hasPrefix("__sevo") { names.insert(name) }
        }
        for match in script.matches(of: #/(?:^|[^\w.$])(g_[A-Z]\w+|[A-Za-z]\w*Store|App(?=\.))(?![\w$])/#) {
            names.insert(String(match.1))
        }
        return names
    }

    /// Capitalized names in the scripts that are the web platform's or the
    /// shim's own, never Steam's.
    static let capitalizedOwn: Set<String> = [
        "CONNECTING", "OPEN", "CLOSING", "CLOSED", "Event", "WebSocket",
    ]

    /// Sources whose markup and style rules are a page of the app's own.
    static let ownPages: Set<String> = ["Sevo/PerfReport.swift"]

    /// Snake-case properties that are the app's own.
    static let snakeOwn: Set<String> = []

    /// What a script reads off `window` that every browser has, or that the
    /// shim itself puts there.
    static let browserGlobals: Set<String> = [
        "SteamClient", "WebSocket", "Event", "addEventListener", "removeEventListener", "blur", "cancelAnimationFrame",
        "clearTimeout", "close", "closed", "dispatchEvent", "document", "fetch", "focus", "getComputedStyle",
        "innerHeight", "innerWidth", "location", "moveTo", "name", "open", "opener", "parent", "postMessage",
        "requestAnimationFrame", "requestIdleCallback", "resizeTo", "screenX", "screenY", "setTimeout", "webkit",
    ]
}

private extension SteamUIBundle.File {
    /// Whether the text reaches `name` through a dot: `.runGame`.
    func containsMember(_ name: String) -> Bool {
        let needle = "." + name
        return offsets(of: needle).contains { offset in
            let after = offset + needle.utf8.count
            return after >= bytes.count || !Self.isName(bytes[after])
        }
    }
}

/// The string literals of Swift source, as the strings they spell.
private enum SwiftLiterals {
    /// Every literal in `source`, escapes resolved and each interpolation
    /// written as `0`. A literal inside an interpolation is listed too.
    static func strings(in source: String) -> [String] {
        var reader = Reader(bytes: Array(source.utf8))
        reader.readCode(untilClosingParenthesis: false)
        return reader.literals
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var literals: [String] = []

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        func starts(with text: String, at offset: Int) -> Bool {
            let wanted = Array(text.utf8)
            return offset + wanted.count <= bytes.count && bytes[offset ..< offset + wanted.count].elementsEqual(wanted)
        }

        /// Reads Swift code, collecting literals; inside an interpolation,
        /// stops past the parenthesis that closes it.
        mutating func readCode(untilClosingParenthesis: Bool) {
            var depth = 0
            while index < bytes.count {
                if starts(with: "//", at: index) {
                    while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                } else if starts(with: "/*", at: index) {
                    index += 2
                    while index < bytes.count, !starts(with: "*/", at: index) { index += 1 }
                    index += 2
                } else if let opening = literalOpening() {
                    readLiteral(opening)
                } else {
                    let byte = bytes[index]
                    index += 1
                    if byte == UInt8(ascii: "(") { depth += 1 }
                    if byte == UInt8(ascii: ")") {
                        if depth == 0, untilClosingParenthesis { return }
                        depth -= 1
                    }
                }
            }
        }

        /// The delimiter of a literal that starts here: its `#` count and
        /// whether it is multi-line.
        func literalOpening() -> (hashes: Int, multiline: Bool)? {
            var cursor = index
            while cursor < bytes.count, bytes[cursor] == UInt8(ascii: "#") { cursor += 1 }
            guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "\"") else { return nil }
            return (cursor - index, starts(with: "\"\"\"", at: cursor))
        }

        mutating func readLiteral(_ opening: (hashes: Int, multiline: Bool)) {
            let pounds = String(repeating: "#", count: opening.hashes)
            let close = (opening.multiline ? "\"\"\"" : "\"") + pounds
            let escape = "\\" + pounds
            index += opening.hashes + (opening.multiline ? 3 : 1)
            var text: [UInt8] = []
            while index < bytes.count, !starts(with: close, at: index) {
                if !opening.multiline, bytes[index] == UInt8(ascii: "\n") { break }
                guard starts(with: escape, at: index), index + escape.utf8.count < bytes.count else {
                    text.append(bytes[index])
                    index += 1
                    continue
                }
                index += escape.utf8.count
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "("):
                    readCode(untilClosingParenthesis: true)
                    text.append(UInt8(ascii: "0"))
                case UInt8(ascii: "n"), UInt8(ascii: "\n"):
                    text.append(UInt8(ascii: "\n"))
                case UInt8(ascii: "t"):
                    text.append(UInt8(ascii: " "))
                default:
                    text.append(escaped)
                }
            }
            index += close.utf8.count
            literals.append(String(decoding: text, as: UTF8.self))
        }
    }
}
