import Foundation

/// The audit: every entry's probe run against one client's files.
nonisolated extension SteamSurface {
    /// A probe's answer.
    enum Status: String, CaseIterable, Codable, Sendable {
        /// The client still has what the app depends on.
        case found
        /// It is gone: the feature built on it will fail.
        case missing
        /// It is there in another shape: an argument count, a parameter
        /// list, a key, a call the app does not answer.
        case changed
        /// The files cannot say.
        case unchecked
    }

    /// One entry's answer.
    struct Finding: Codable, Sendable, Equatable {
        let kind: Kind
        let name: String
        let use: String
        let status: Status
        /// What the probe saw, or why it could not look.
        let detail: String
    }

    /// One client's answers, as `sevo steam audit --json` prints them.
    struct Report: Codable, Sendable, Equatable {
        /// The audited folder.
        let bundle: String
        /// The client's UI build number.
        let version: String?
        let entries: Int
        let found: Int
        let missing: Int
        let changed: Int
        let unchecked: Int
        let findings: [Finding]

        init(bundle: String, version: String?, findings: [Finding]) {
            self.bundle = bundle
            self.version = version
            self.findings = findings
            entries = findings.count
            found = findings.count { $0.status == .found }
            missing = findings.count { $0.status == .missing }
            changed = findings.count { $0.status == .changed }
            unchecked = findings.count { $0.status == .unchecked }
        }

        /// One line per entry that is missing or changed, then the totals.
        var lines: [String] {
            let flagged = findings.filter { $0.status == .missing || $0.status == .changed }
            return flagged.map(\.line) + [summary]
        }

        var summary: String {
            let build = version.map { "Steam UI \($0)" } ?? "Steam UI of an unknown build"
            return "\(build): \(entries) entries, \(found) found, \(missing) missing, "
                + "\(changed) changed, \(unchecked) unchecked"
        }
    }

    /// Runs every probe of `entries` against `bundle`.
    static func audit(_ bundle: SteamUIBundle, at path: String = "", entries: [Entry] = catalog) -> Report {
        let findings = entries.map { entry in
            let (status, detail) = answer(for: entry, in: bundle)
            return Finding(kind: entry.kind, name: entry.name, use: entry.use, status: status, detail: detail)
        }
        return Report(bundle: path, version: bundle.version, findings: findings)
    }

    /// One entry's answer.
    static func answer(for entry: Entry, in bundle: SteamUIBundle) -> (Status, String) {
        switch entry.probe {
        case let .call(passes, steamCalls, handler):
            call(entry.name, passes: passes, steamCalls: steamCalls, handler: handler, in: bundle)
        case .global:
            global(entry.name, in: bundle)
        case let .identifier(passes):
            identifier(entry.name, passes: passes, in: bundle)
        case let .classMap(signature, limit):
            classMap(signature: signature, keys: entry.tokens, limit: limit, in: bundle)
        case let .text(needles):
            text(needles, in: bundle)
        case .cssClass:
            cssClass(entry.name, in: bundle)
        case let .supplied(surface):
            supplied(surface, in: bundle)
        case .chromium:
            chromium(in: bundle)
        case let .unchecked(reason):
            (.unchecked, reason)
        }
    }
}

nonisolated extension SteamSurface.Finding {
    /// `missing  call  SteamClient.Apps.RunGame: … (launching a game)`.
    var line: String {
        "\(status.rawValue)  \(kind.rawValue)  \(name): \(detail) (\(use))"
    }
}

// MARK: - Probes

private nonisolated extension SteamSurface {
    /// Steam's own calls of one `SteamClient` method: their argument counts,
    /// and for a registration the parameter counts of the handlers passed.
    static func call(
        _ path: String, passes: Int?, steamCalls: Bool, handler: [Int]?, in bundle: SteamUIBundle,
    ) -> (Status, String) {
        guard let dot = path.lastIndex(of: ".") else { return (.unchecked, "not a method path") }
        let receiver = String(path[..<dot])
        let needle = String(path[dot...]) + "("
        var counts: Set<Int> = []
        var handlers: Set<Int> = []
        for file in bundle.scripts {
            for offset in file.offsets(of: needle) {
                // `SteamClient.Apps?.AddShortcut(` is the same call.
                let before = file.text(offset - 96 ..< offset).replacingOccurrences(of: "?", with: "")
                guard before.hasSuffix(receiver),
                      let (arguments, _) = file.arguments(from: offset + needle.utf8.count)
                else { continue }
                counts.insert(arguments.count)
                guard handler != nil else { continue }
                for argument in arguments { handlers.formUnion(parameterCounts(ofHandler: argument, in: file)) }
            }
        }
        guard let fewest = counts.min(), let most = counts.max() else {
            return steamCalls
                ? (.missing, "Steam's own code no longer calls it")
                : (.unchecked, "Steam's own code does not call it, so only a running client can answer")
        }
        let steam = list(counts)
        if let passes, passes < fewest {
            return (.changed, "the app passes \(passes), Steam's own code passes \(steam); the client refuses a short call")
        }
        if let passes, passes > most {
            return (.changed, "the app passes \(passes), Steam's own code passes \(steam)")
        }
        if let handler, !handlers.isSubset(of: handler) {
            return (.changed, "Steam's own handlers take \(list(handlers)) parameters, \(list(Set(handler))) when this entry was written")
        }
        let taken = handlers.isEmpty ? "" : ", its handlers take \(list(handlers))"
        return (.found, "Steam passes \(steam)\(taken)")
    }

    static func list(_ counts: Set<Int>) -> String {
        counts.sorted().map(String.init).joined(separator: " or ")
    }

    /// The parameter counts of a callback argument: written in place, or a
    /// method named as `this.OnThing` and defined in the same file.
    static func parameterCounts(ofHandler argument: String, in file: SteamUIBundle.File) -> Set<Int> {
        if let named = argument.wholeMatch(of: #/(?:this|[\w$]+)\.([\w$]+)/#) {
            return Set(file.definitions(of: String(named.1)).map(\.count))
        }
        if let arrow = argument.prefixMatch(of: #/(?:async\s*)?\(([^()]*)\)\s*=>/#) {
            return [parameters(in: String(arrow.1))]
        }
        if argument.prefixMatch(of: #/(?:async\s+)?[\w$]+\s*=>/#) != nil { return [1] }
        if let function = argument.prefixMatch(of: #/(?:async\s+)?function\s*[\w$]*\(([^()]*)\)/#) {
            return [parameters(in: String(function.1))]
        }
        return []
    }

    static func parameters(in list: String) -> Int {
        list.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : list.split(separator: ",").count
    }

    static func global(_ name: String, in bundle: SteamUIBundle) -> (Status, String) {
        for file in bundle.scripts {
            for owner in ["window", "self", "globalThis"] {
                let needle = "\(owner).\(name)="
                for offset in file.offsets(of: needle) {
                    let after = offset + needle.utf8.count
                    if after < file.bytes.count, file.bytes[after] == UInt8(ascii: "=") { continue }
                    return (.found, "assigned in \(file.path)")
                }
            }
        }
        return (.missing, "no script assigns window.\(name)")
    }

    static func identifier(_ name: String, passes: Int?, in bundle: SteamUIBundle) -> (Status, String) {
        guard let home = bundle.scripts.first(where: { !$0.wordOffsets(of: name).isEmpty }) else {
            return (.missing, "no script names it")
        }
        guard let passes else { return (.found, "named in \(home.path)") }
        let definitions = bundle.scripts.flatMap { $0.definitions(of: name) }
        guard !definitions.isEmpty else { return (.found, "named in \(home.path); its definition was not located") }
        let shapes = Set(definitions.map { "(\($0.joined(separator: ",")))" }).sorted().joined(separator: " ")
        // A definition takes the call when no parameter past the ones passed is required.
        let taken = definitions.contains { required(in: $0) <= passes }
        return taken
            ? (.found, "defined as \(shapes)")
            : (.changed, "the app passes \(passes), every definition requires more: \(shapes)")
    }

    /// The parameters before the first default or rest parameter.
    static func required(in parameters: [String]) -> Int {
        parameters.prefix { !$0.contains("=") && !$0.hasPrefix("...") }.count
    }

    static func classMap(
        signature: [String], keys: [String], limit: Int, in bundle: SteamUIBundle,
    ) -> (Status, String) {
        guard let first = signature.first else { return (.unchecked, "no signature key") }
        var nearest: (Status, String)?
        for file in bundle.scripts {
            for offset in file.offsets(ofQuoted: first + ":\"") {
                guard let (found, length) = file.flatObject(around: offset),
                      signature.allSatisfy(found.contains)
                else { continue }
                let lost = keys.filter { !found.contains($0) }
                if !lost.isEmpty {
                    nearest = (.changed, "the class map lacks \(lost.joined(separator: ", "))")
                } else if length + Self.moduleWrapper > limit {
                    nearest = (.changed, "the class map is \(length) characters; the app reads modules under \(limit)")
                } else {
                    return (.found, "\(found.count) classes in \(file.path)")
                }
            }
        }
        return nearest ?? (.missing, "no class map holds \(signature.joined(separator: " and "))")
    }

    /// What webpack writes around a class map: `e=>{e.exports=…}`.
    static let moduleWrapper = 24

    static func text(_ needles: [String], in bundle: SteamUIBundle) -> (Status, String) {
        let lost = needles.filter { needle in !bundle.scripts.contains { $0.containsQuoted(needle) } }
        return lost.isEmpty
            ? (.found, "in the scripts")
            : (.missing, "no script holds \(lost.map { "‘\($0)’" }.joined(separator: ", "))")
    }

    static func cssClass(_ name: String, in bundle: SteamUIBundle) -> (Status, String) {
        let dash: Set<UInt8> = [UInt8(ascii: "-")]
        let selector = "." + name
        let styled = bundle.styles.first { sheet in
            sheet.offsets(of: selector).contains { offset in
                let after = offset + selector.utf8.count
                return after >= sheet.bytes.count || !SteamUIBundle.File.isName(sheet.bytes[after], dash)
            }
        }
        if let styled { return (.found, "styled in \(styled.path)") }
        if let script = bundle.scripts.first(where: { !$0.wordOffsets(of: name, extra: dash).isEmpty }) {
            return (.found, "named in \(script.path)")
        }
        return (.missing, "no style sheet or script names the class")
    }

    static func supplied(_ surface: Supplied, in bundle: SteamUIBundle) -> (Status, String) {
        var called: Set<String> = []
        for file in bundle.scripts {
            switch surface.shape {
            case let .namespace(namespace):
                called.formUnion(methods(calledOn: namespace, in: file))
            case let .receivers(receivers):
                for receiver in receivers { called.formUnion(methods(calledOn: receiver, in: file)) }
            case .listeners:
                called.formUnion(listenedEvents(in: file))
            }
        }
        guard !called.isEmpty else { return (.missing, "Steam's code makes no such call; the surface moved") }
        let unanswered = called.subtracting(surface.answered).subtracting(surface.ignored).sorted()
        return unanswered.isEmpty
            ? (.found, "Steam uses \(called.count) names, each answered or set aside")
            : (.changed, "Steam uses \(unanswered.joined(separator: ", ")), which the app does not answer")
    }

    /// The capitalized methods called on `receiver`, a dotted path whose
    /// links may be optional (`SteamClient.Window?.Close(`).
    static func methods(calledOn receiver: String, in file: SteamUIBundle.File) -> Set<String> {
        let links = receiver.split(separator: ".").map(String.init)
        guard let head = links.first else { return [] }
        var names: Set<String> = []
        for offset in file.wordOffsets(of: head) {
            var index = offset + head.utf8.count
            var matched = true
            for link in links.dropFirst() {
                guard let next = file.skippingDot(at: index), file.text(next ..< next + link.utf8.count) == link else {
                    matched = false
                    break
                }
                index = next + link.utf8.count
            }
            guard matched, let start = file.skippingDot(at: index) else { continue }
            var end = start
            while end < file.bytes.count, SteamUIBundle.File.isName(file.bytes[end]) { end += 1 }
            guard end > start, end < file.bytes.count, file.bytes[end] == UInt8(ascii: "("),
                  (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(file.bytes[start])
            else { continue }
            names.insert(file.text(start ..< end))
        }
        return names
    }

    /// The events Steam's code subscribes to with `.on("…",`.
    static func listenedEvents(in file: SteamUIBundle.File) -> Set<String> {
        let needle = ".on(\""
        var events: Set<String> = []
        for offset in file.offsets(ofQuoted: needle) {
            let start = offset + needle.utf8.count
            var end = start
            while end < file.bytes.count, end < start + 64, !SteamUIBundle.File.isQuote(file.bytes[end]) { end += 1 }
            events.insert(file.text(start ..< end))
        }
        return events
    }

    static func chromium(in bundle: SteamUIBundle) -> (Status, String) {
        let findings = bundle.scripts.flatMap { ChromiumSurface.audit(Array($0.bytes), file: $0.path) }
        guard !findings.isEmpty else { return (.found, "every Chromium-only call is guarded or supplied") }
        let names = Set(findings.map(\.api)).sorted().joined(separator: ", ")
        return (.missing, "Steam calls \(names) without checking for it, and the shim does not supply it")
    }
}

private nonisolated extension SteamUIBundle.File {
    /// The offset past a `.` or `?.` at `index`.
    func skippingDot(at index: Int) -> Int? {
        var index = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "?") { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: ".") else { return nil }
        return index + 1
    }
}
