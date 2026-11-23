import Foundation

/// The scripts and style sheets of one Steam client's `steamui` folder, held
/// as bytes for ``SteamSurface``'s probes to search.
///
/// The files are read and searched as text. Nothing in the folder is run, so
/// a downloaded client's package is as safe to audit as the bottle's own.
nonisolated struct SteamUIBundle: Sendable {
    /// One file of the bundle.
    struct File: Sendable {
        /// The path inside `steamui`.
        let path: String
        let bytes: ContiguousArray<UInt8>

        init(path: String, bytes: ContiguousArray<UInt8>) {
            self.path = path
            self.bytes = bytes
        }

        init(path: String, text: String) {
            self.init(path: path, bytes: ContiguousArray(text.utf8))
        }
    }

    /// The JavaScript chunks, the localization tables left out.
    let scripts: [File]
    let styles: [File]
    /// The client's UI build number (`changelist.txt`), when the folder has one.
    let version: String?

    init(scripts: [File], styles: [File] = [], version: String? = nil) {
        self.scripts = scripts
        self.styles = styles
        self.version = version
    }

    /// A made-up bundle of one script, for tests.
    init(script: String, style: String = "") {
        self.init(
            scripts: [File(path: "sp.js", text: script)],
            styles: style.isEmpty ? [] : [File(path: "css/sp.css", text: style)],
        )
    }

    enum LoadFailure: Error, Equatable {
        /// The folder holds no script: it is not a `steamui` folder.
        case noScripts(String)
    }

    /// Reads every script and style sheet under `folder`.
    init(folder: URL) throws {
        let manager = FileManager.default
        let paths = ((try? manager.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var scripts: [File] = []
        var styles: [File] = []
        for path in paths where !path.hasPrefix(Self.localization) {
            let isScript = path.hasSuffix(".js")
            guard isScript || path.hasSuffix(".css"),
                  let data = try? Data(contentsOf: folder.appendingPathComponent(path))
            else { continue }
            let file = File(path: path, bytes: ContiguousArray(data))
            if isScript { scripts.append(file) } else { styles.append(file) }
        }
        guard !scripts.isEmpty else { throw LoadFailure.noScripts(folder.path) }
        let changelist = try? String(contentsOf: folder.appendingPathComponent("changelist.txt"), encoding: .utf8)
        self.init(
            scripts: scripts, styles: styles,
            version: changelist?.trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }

    /// String tables, 60 MB of them, which name nothing the app depends on.
    private static let localization = "localization/"
}

// MARK: - Searching

nonisolated extension SteamUIBundle.File {
    /// Where `needle` occurs, in order.
    func offsets(of needle: String) -> [Int] {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return [] }
        var found: [Int] = []
        bytes.withUnsafeBytes { haystack in
            pattern.withUnsafeBytes { wanted in
                guard let base = haystack.baseAddress, let needleBase = wanted.baseAddress else { return }
                var from = 0
                while from <= haystack.count - wanted.count,
                      let hit = memmem(base + from, haystack.count - from, needleBase, wanted.count) {
                    let offset = base.distance(to: UnsafeRawPointer(hit))
                    found.append(offset)
                    from = offset + 1
                }
            }
        }
        return found
    }

    func contains(_ needle: String) -> Bool {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return false }
        return bytes.withUnsafeBytes { haystack in
            pattern.withUnsafeBytes { wanted in
                memmem(haystack.baseAddress, haystack.count, wanted.baseAddress, wanted.count) != nil
            }
        }
    }

    /// `needle` with each `"` written as each of JavaScript's three quotes.
    /// A minifier picks the quote: webpack builds of the client write `"…"`,
    /// its Rollup builds write backticks.
    static func quoteVariants(_ needle: String) -> [String] {
        guard needle.contains("\"") else { return [needle] }
        return ["\"", "'", "`"].map { needle.replacingOccurrences(of: "\"", with: $0) }
    }

    /// Whether `needle` occurs, whichever quote the file writes strings with.
    func containsQuoted(_ needle: String) -> Bool {
        Self.quoteVariants(needle).contains(where: contains)
    }

    /// Where `needle` occurs, whichever quote the file writes strings with.
    func offsets(ofQuoted needle: String) -> [Int] {
        Self.quoteVariants(needle).flatMap(offsets(of:)).sorted()
    }

    static func isQuote(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") || byte == UInt8(ascii: "`")
    }

    /// Where `word` stands alone: the bytes on either side are not part of a
    /// name. `extra` adds bytes that count as part of one (`-` in a CSS class).
    func wordOffsets(of word: String, extra: Set<UInt8> = []) -> [Int] {
        let length = word.utf8.count
        return offsets(of: word).filter { offset in
            let before = offset > 0 ? bytes[offset - 1] : UInt8(ascii: " ")
            let after = offset + length < bytes.count ? bytes[offset + length] : UInt8(ascii: " ")
            return !Self.isName(before, extra) && !Self.isName(after, extra)
        }
    }

    /// The text of `range`, clamped to the file.
    func text(_ range: Range<Int>) -> String {
        let lower = max(0, range.lowerBound)
        let upper = min(bytes.count, range.upperBound)
        guard lower < upper else { return "" }
        return String(decoding: bytes[lower ..< upper], as: UTF8.self)
    }

    /// A few characters either side of `offset`, for a finding's detail.
    func excerpt(around offset: Int, radius: Int = 60) -> String {
        text(offset - radius ..< offset + radius)
    }

    static func isName(_ byte: UInt8, _ extra: Set<UInt8> = []) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || extra.contains(byte)
    }
}

// MARK: - Reading minified JavaScript

nonisolated extension SteamUIBundle.File {
    /// The top-level arguments of the call whose `(` ends just before `start`,
    /// each as written, and the offset just past its `)`. Nil when the call
    /// does not close within ``callWindow`` bytes.
    func arguments(from start: Int) -> (list: [String], end: Int)? {
        var depth = 0
        var quote: UInt8?
        var pieces: [String] = []
        var pieceStart = start
        var index = start
        let limit = min(bytes.count, start + Self.callWindow)
        while index < limit {
            let byte = bytes[index]
            if let open = quote {
                if byte == UInt8(ascii: "\\") { index += 2; continue }
                if byte == open { quote = nil }
            } else if Self.isQuote(byte) {
                quote = byte
            } else if byte == UInt8(ascii: "(") || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: ")") || byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}") {
                if depth == 0 {
                    let last = text(pieceStart ..< index).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !last.isEmpty || !pieces.isEmpty { pieces.append(last) }
                    return (pieces, index + 1)
                }
                depth -= 1
            } else if byte == UInt8(ascii: ","), depth == 0 {
                pieces.append(text(pieceStart ..< index).trimmingCharacters(in: .whitespacesAndNewlines))
                pieceStart = index + 1
            }
            index += 1
        }
        return nil
    }

    /// How far a call's closing parenthesis may be from its opening one.
    private static let callWindow = 6000

    /// The parameter lists of every definition of the method or function
    /// `name`: `name(a,b){`, `name=(a,b)=>`, `name=a=>` and
    /// `name=function(a,b){`.
    func definitions(of name: String) -> [[String]] {
        var lists: [[String]] = []
        let length = name.utf8.count
        for offset in wordOffsets(of: name) {
            // A name reached through a dot is a use of it.
            if offset > 0, bytes[offset - 1] == UInt8(ascii: ".") { continue }
            var index = offset + length
            guard index < bytes.count else { continue }
            if bytes[index] == UInt8(ascii: "(") {
                guard let (list, end) = arguments(from: index + 1), end < bytes.count,
                      bytes[end] == UInt8(ascii: "{")
                else { continue }
                lists.append(list)
                continue
            }
            guard bytes[index] == UInt8(ascii: "="), index + 1 < bytes.count,
                  bytes[index + 1] != UInt8(ascii: "=")
            else { continue }
            index += 1
            let head = text(index ..< index + 24)
            for prefix in ["async function", "function", "async"] where head.hasPrefix(prefix) {
                index += prefix.utf8.count
                break
            }
            while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
            guard index < bytes.count else { continue }
            if bytes[index] == UInt8(ascii: "(") {
                guard let (list, end) = arguments(from: index + 1) else { continue }
                let next = text(end ..< end + 2)
                if next.hasPrefix("=>") || next.hasPrefix("{") { lists.append(list) }
            } else {
                var end = index
                while end < bytes.count, Self.isName(bytes[end]) { end += 1 }
                if end > index, text(end ..< end + 2) == "=>" { lists.append([text(index ..< end)]) }
            }
        }
        return lists
    }

    /// The flat object literal around `offset` (a CSS-module class map),
    /// with its keys. Nil when the braces around `offset` hold nested ones.
    func flatObject(around offset: Int) -> (keys: Set<String>, length: Int)? {
        var lower = offset
        while lower >= 0, bytes[lower] != UInt8(ascii: "{") {
            if bytes[lower] == UInt8(ascii: "}") { return nil }
            lower -= 1
        }
        var upper = offset
        while upper < bytes.count, bytes[upper] != UInt8(ascii: "}") {
            if bytes[upper] == UInt8(ascii: "{") { return nil }
            upper += 1
        }
        guard lower >= 0, upper < bytes.count else { return nil }
        var keys: Set<String> = []
        var index = lower + 1
        while index < upper {
            // A key runs to its colon; its value is a quoted string.
            var keyEnd = index
            while keyEnd < upper, bytes[keyEnd] != UInt8(ascii: ":") { keyEnd += 1 }
            let key = text(index ..< keyEnd).trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
            if !key.isEmpty { keys.insert(key) }
            var valueEnd = keyEnd + 1
            if valueEnd < upper, Self.isQuote(bytes[valueEnd]) {
                let quote = bytes[valueEnd]
                valueEnd += 1
                while valueEnd < upper, bytes[valueEnd] != quote { valueEnd += 1 }
            }
            while valueEnd < upper, bytes[valueEnd] != UInt8(ascii: ",") { valueEnd += 1 }
            index = valueEnd + 1
        }
        return (keys, upper - lower + 1)
    }
}
