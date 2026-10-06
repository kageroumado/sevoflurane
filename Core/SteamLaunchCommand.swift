import Foundation

/// Steam's per-game launch options in the form Proton fixes are shared in:
/// `DXVK_HUD=1 PROTON_USE_WINED3D=1 %command% -windowed`.
///
/// Steam for Linux runs that line through a shell, with `%command%` standing
/// for the game. The Windows client in the bottle substitutes `%command%` and
/// starts the first word of the result as the program, so a line with
/// anything ahead of `%command%` starts a program called `DXVK_HUD=1` and the
/// game never runs. Sevoflurane takes the words ahead of `%command%` out of
/// the line: the assignments become the game's own Environment (or the row
/// that does the same thing here), and Steam keeps the line from `%command%`
/// on, which it runs as written.
nonisolated struct SteamLaunchCommand: Equatable, Sendable {
    /// One `NAME=value` word, unquoted.
    struct Assignment: Equatable, Sendable {
        let name: String
        let value: String
    }

    /// The assignments ahead of `%command%`, in the order they were written.
    let assignments: [Assignment]
    /// The other words ahead of `%command%`: the programs Linux runs the game
    /// through (`gamemoderun`, `mangohud`, `taskset -c 0-3`), which have no
    /// meaning in the bottle.
    let wrappers: [String]
    /// The text Steam keeps: the line from the first `%command%` on, as
    /// written.
    let remainder: String

    static let placeholder = "%command%"

    /// The line's words ahead of `%command%`, or `nil` when there is nothing
    /// to take out: no `%command%`, or `%command%` is the first word. Steam
    /// handles both of those itself.
    ///
    /// Words are split the way a POSIX shell splits them: single quotes keep
    /// everything, double quotes keep everything but `\"`, `\\`, `` \` `` and
    /// `\$`, a backslash outside quotes keeps the next character, and an
    /// unclosed quote runs to the end of the line. A word is an assignment
    /// when its name and `=` stand unquoted ahead of everything else; after
    /// the first word that is not one, assignments are that program's
    /// arguments, except after `env`, whose arguments are assignments.
    static func parse(_ options: String) -> SteamLaunchCommand? {
        let words = split(options)
        guard let command = words.firstIndex(where: { $0.text == placeholder }), command > 0 else { return nil }
        var assignments: [Assignment] = []
        var wrappers: [String] = []
        for word in words[..<command] {
            if wrappers.isEmpty, let assignment = word.assignment {
                assignments.append(assignment)
            } else if wrappers.isEmpty, word.text == "env" {
                continue
            } else {
                wrappers.append(word.text)
            }
        }
        let remainder = options[words[command].start...].trimmingCharacters(in: .whitespacesAndNewlines)
        return SteamLaunchCommand(assignments: assignments, wrappers: wrappers, remainder: remainder)
    }

    // MARK: - Words

    struct Word: Equatable {
        /// The word with its quotes and escapes resolved.
        var text: String
        /// Where the word begins in the line.
        let start: String.Index
        /// The characters ahead of the first quote or escape, which is where
        /// an assignment's name and `=` have to be.
        var bare: String

        var assignment: Assignment? {
            guard let equals = bare.firstIndex(of: "=") else { return nil }
            let name = String(bare[..<equals])
            guard UserEnvironment.isValidName(name) else { return nil }
            return Assignment(name: name, value: String(text.dropFirst(name.count + 1)))
        }
    }

    static func split(_ line: String) -> [Word] {
        var words: [Word] = []
        var current: Word?
        var quoted = false
        var index = line.startIndex

        func append(_ character: Character, at position: String.Index, bare: Bool) {
            if current == nil { current = Word(text: "", start: position, bare: "") }
            current?.text.append(character)
            if bare, !quoted { current?.bare.append(character) }
        }

        func begin(at position: String.Index) {
            if current == nil { current = Word(text: "", start: position, bare: "") }
            quoted = true
        }

        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            switch character {
            case _ where character.isWhitespace:
                if let word = current { words.append(word) }
                current = nil
                quoted = false
                index = next
            case "'":
                begin(at: index)
                let close = line[next...].firstIndex(of: "'") ?? line.endIndex
                for literal in line[next ..< close] {
                    append(literal, at: index, bare: false)
                }
                index = close < line.endIndex ? line.index(after: close) : close
            case "\"":
                begin(at: index)
                index = next
                while index < line.endIndex, line[index] != "\"" {
                    let after = line.index(after: index)
                    if line[index] == "\\", after < line.endIndex, "\"\\$`".contains(line[after]) {
                        append(line[after], at: index, bare: false)
                        index = line.index(after: after)
                    } else {
                        append(line[index], at: index, bare: false)
                        index = after
                    }
                }
                if index < line.endIndex { index = line.index(after: index) }
            case "\\":
                begin(at: index)
                if next < line.endIndex {
                    append(line[next], at: index, bare: false)
                    index = line.index(after: next)
                } else {
                    index = next
                }
            default:
                append(character, at: index, bare: true)
                index = next
            }
        }
        if let word = current { words.append(word) }
        return words
    }

    // MARK: - Applying

    /// What the assignments make of a game's own values, and one line per
    /// word saying where it went. Proton's switches that have a row here set
    /// that row; every other valid name joins the game's Environment, Proton's
    /// own names included, since a game or a layer can read them.
    func apply(to values: inout ConfigValues) -> [String] {
        var notes: [String] = []
        var table = values.environment ?? [:]
        for assignment in assignments {
            if let note = Self.applyProtonSwitch(assignment, to: &values) {
                notes.append(note)
                continue
            }
            if let problem = UserEnvironment.problem(name: assignment.name, value: assignment.value) {
                notes.append("\(assignment.name) left out: \(problem.message)")
                continue
            }
            table[assignment.name] = assignment.value
            notes.append("\(assignment.name)=\(assignment.value) → Environment")
        }
        values.environment = table.isEmpty ? nil : table
        if !wrappers.isEmpty {
            notes.append("left out \(wrappers.joined(separator: " ")): Linux programs the game runs through")
        }
        return notes
    }

    /// Proton's switches with a setting of their own here. `nil` for any
    /// other name; a switch set to `0` or nothing is off, which is every
    /// row's default, so it is dropped.
    private static func applyProtonSwitch(_ assignment: Assignment, to values: inout ConfigValues) -> String? {
        let on = !assignment.value.isEmpty && assignment.value != "0"
        switch assignment.name {
        case "PROTON_USE_WINED3D":
            guard on else { return "\(assignment.name)=\(assignment.value) left out: off" }
            values.renderer = .wined3d
            return "\(assignment.name)=\(assignment.value) → Renderer: \(Renderer.wined3d.label)"
        case "PROTON_FORCE_LARGE_ADDRESS_AWARE":
            guard on else { return "\(assignment.name)=\(assignment.value) left out: off" }
            values.largeAddressAware = true
            return "\(assignment.name)=\(assignment.value) → \(SettingCatalog.setting(.largeAddressAware).title): on"
        default:
            return nil
        }
    }
}

// MARK: - Taking the line apart for Steam

nonisolated extension SteamLaunchCommand {
    /// The app id a `RunGame` or `SetAppLaunchOptions` call names, when it is
    /// a Steam app's: the first argument, a number or its text. A non-Steam
    /// shortcut's 64-bit game id and an adopted program's id name no launch
    /// options this reads.
    static func appID(inArguments arguments: [Any]?) -> Int? {
        guard let first = arguments?.first else { return nil }
        let id = (first as? NSNumber)?.intValue ?? Int("\(first)")
        guard let id, id > 0, id < AdoptedPrograms.firstID else { return nil }
        return id
    }

    /// Moves the words ahead of `%command%` into the game's own settings and
    /// answers the line Steam keeps, with one note per word; `nil` when the
    /// line is Steam's to run as it is.
    static func adopt(
        _ options: String, appID: Int, bottle: String, prefix: URL,
    ) -> (remainder: String, notes: [String])? {
        guard let command = parse(options) else { return nil }
        var notes: [String] = []
        GameConfig.update(game: appID, bottle: bottle, prefix: prefix) { values in
            notes = command.apply(to: &values)
        }
        return (command.remainder, notes)
    }

    /// A script for the client's own context that answers an app's launch
    /// options, or `null` when Steam has no details for it within five
    /// seconds.
    static func readScript(appID: Int) -> String {
        """
        new Promise(function (resolve) {
          var registration = null, done = false;
          var finish = function (value) {
            if (done) return;
            done = true;
            setTimeout(function () { try { registration.unregister(); } catch (e) {} }, 0);
            resolve(value);
          };
          registration = SteamClient.Apps.RegisterForAppDetails(\(appID), function (details) {
            finish(details && typeof details.strLaunchOptions === "string" ? details.strLaunchOptions : "");
          });
          setTimeout(function () { finish(null); }, 5000);
        })
        """
    }

    /// A script for the client's own context that stores an app's launch
    /// options.
    static func storeScript(appID: Int, options: String) -> String {
        "SteamClient.Apps.SetAppLaunchOptions(\(appID), \(JSLiteral.string(options))); \"stored\""
    }
}
