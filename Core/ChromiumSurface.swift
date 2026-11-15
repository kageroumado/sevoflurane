import Foundation

/// The Chromium APIs Steam's UI bundle may call that WebKit lacks, and the
/// audit that finds the bundle calling one without checking for it first.
///
/// Steam writes its UI for CEF and updates it on its own schedule. A call to a
/// Chromium-only function that the bundle does not feature-detect throws in
/// WebKit, and Steam's error boundary replaces the whole window with "Something
/// went wrong while displaying this content". The shim supplies the ones the
/// bundle calls (`supplyChromiumSurface` in `steamclient_shim.js`); this audit
/// runs on every new bundle and names any call the shim does not cover, so the
/// next one is in the log before anyone opens Steam.
nonisolated enum ChromiumSurface {
    /// A Chromium-only function or constructor, absent from WKWebView on
    /// macOS 27, and the text that marks a call to it in minified code.
    struct API: Hashable, Sendable {
        /// The name as a reader would look it up, `scheduler.postTask`.
        let name: String
        /// The identifier a call site contains. A member reached through a
        /// renamed local (`h1.getHighEntropyValues(`) is matched by its last
        /// component, which minification keeps.
        let token: String

        init(_ name: String, token: String? = nil) {
            self.name = name
            self.token = token ?? String(name.split(separator: ".").last ?? Substring(name))
        }
    }

    /// Functions and constructors Chromium ships and WKWebView does not,
    /// each checked against a live WKWebView on macOS 27.
    static let chromiumOnly: [API] = [
        API("requestIdleCallback"),
        API("cancelIdleCallback"),
        API("scheduler.postTask", token: "scheduler.postTask"),
        API("scheduler.yield", token: "scheduler.yield"),
        API("TaskController"),
        API("navigator.scheduling.isInputPending"),
        API("navigator.userAgentData.getHighEntropyValues"),
        API("navigator.keyboard.getLayoutMap"),
        API("EyeDropper"),
        API("showOpenFilePicker"),
        API("showSaveFilePicker"),
        API("showDirectoryPicker"),
        API("queryLocalFonts"),
        API("IdleDetector"),
        API("ImageDecoder"),
        API("MediaStreamTrackProcessor"),
        API("getScreenDetails"),
    ]

    /// The members `supplyChromiumSurface` installs on every window.
    static let suppliedByShim: Set<String> = [
        "requestIdleCallback",
        "cancelIdleCallback",
    ]

    /// One call the shim does not cover, with the code around it.
    struct Finding: Equatable, Sendable {
        let api: String
        let file: String
        let excerpt: String
    }

    /// The unguarded calls in one script to Chromium-only APIs the shim does
    /// not supply.
    ///
    /// A call counts as guarded when the code just before it tests for the
    /// name (`"EyeDropper" in window`, `typeof x.requestIdleCallback`,
    /// `x.foo && x.foo(`, `x.foo?.(`), which is how the bundle writes every
    /// optional API it already handles.
    static func audit(_ source: String, file: String) -> [Finding] {
        audit(Array(source.utf8), file: file)
    }

    /// Every script in a Steam UI folder, audited.
    static func audit(bundle: URL) -> [Finding] {
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: bundle.path)) ?? []
        return files.sorted().filter { $0.hasSuffix(".js") }.flatMap { path -> [Finding] in
            guard let data = try? Data(contentsOf: bundle.appendingPathComponent(path)) else { return [] }
            return audit(Array(data), file: path)
        }
    }

    /// The log line for one finding.
    static func sentence(for finding: Finding) -> String {
        "Steam's UI calls \(finding.api) without checking for it, and WebKit does not have it — "
            + "the window that reaches this call will fail with \"Something went wrong\". "
            + "Supply it in supplyChromiumSurface (steamclient_shim.js). "
            + "\(finding.file): …\(finding.excerpt)…"
    }

    // MARK: - Matching

    /// One pass over the bytes: at every `(`, the identifier before it is
    /// looked up among the tokens. sp.js alone is 16 MB and the bundle 80;
    /// a search per token through a String took ten seconds.
    private static func audit(_ text: [UInt8], file: String) -> [Finding] {
        let wanted = chromiumOnly.filter { !suppliedByShim.contains($0.name) }
        let byMember = Dictionary(grouping: wanted) { member(of: $0.token) }
        let lengths = Set(byMember.keys.map(\.utf8.count))
        var findings: [Finding] = []
        var reported: Set<String> = []
        text.withUnsafeBufferPointer { bytes in
            for index in bytes.indices where bytes[index] == UInt8(ascii: "(") {
                var start = index
                while start > 0, isIdentifier(bytes[start - 1]) { start -= 1 }
                guard lengths.contains(index - start) else { continue }
                let name = String(decoding: bytes[start..<index], as: UTF8.self)
                for api in byMember[name] ?? [] where !reported.contains(api.name) {
                    guard hasQualifier(api.token, endingAt: start, in: bytes),
                          !isGuarded(api.token, before: start, in: bytes)
                    else { continue }
                    reported.insert(api.name)
                    findings.append(Finding(api: api.name, file: file, excerpt: slice(bytes, start - 80, start + 80)))
                }
            }
        }
        return findings
    }

    private static func member(of token: String) -> String {
        String(token.split(separator: ".").last ?? Substring(token))
    }

    /// A dotted token (`scheduler.postTask`) needs its qualifier in front of
    /// the member, and the qualifier must start an identifier itself.
    private static func hasQualifier(
        _ token: String, endingAt start: Int, in bytes: UnsafeBufferPointer<UInt8>,
    ) -> Bool {
        let qualifier = Array(token.utf8.dropLast(member(of: token).utf8.count))
        guard !qualifier.isEmpty else { return true }
        let from = start - qualifier.count
        guard from >= 0, bytes[from..<start].elementsEqual(qualifier) else { return false }
        return from == 0 || !isIdentifier(bytes[from - 1])
    }

    private static func isIdentifier(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$")
    }

    private static let guardWindow = 400

    private static func isGuarded(_ token: String, before index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let window = slice(bytes, index - guardWindow, index)
        let name = member(of: token)
        let tests = [
            "\"\(name)\"in", "\"\(name)\" in", "'\(name)'in", "'\(name)' in",
            "typeof \(token)", "typeof window.\(token)",
            ".\(name)&&", ".\(name) &&", ".\(name)?", ".\(name)!=", ".\(name)==",
        ]
        if tests.contains(where: window.contains) { return true }
        return window.range(of: #"typeof [\w$.]*\.\#(name)\b"#, options: .regularExpression) != nil
    }

    private static func slice(_ bytes: UnsafeBufferPointer<UInt8>, _ lower: Int, _ upper: Int) -> String {
        String(decoding: bytes[max(0, lower)..<min(bytes.count, upper)], as: UTF8.self)
    }
}
