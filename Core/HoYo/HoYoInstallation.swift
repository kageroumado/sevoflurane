import Foundation

/// A HoYoverse game's folder: which game, which build, and the files it
/// should hold.
///
/// The build is the `game_version` line of the folder's `config.ini`, which
/// HoYoPlay writes and every launcher reads. The files are the folder's
/// `pkg_version` (and `Audio_<language>_pkg_version` beside it): one JSON
/// object per line, `{"remoteName", "md5", "fileSize"}`, which the game's
/// own build ships and a finished download leaves in place.
nonisolated struct HoYoInstallation: Sendable {
    let game: HoYoGame
    let folder: URL

    /// The folder's installation, if a HoYoverse game's executable is in it.
    init?(folder: URL) {
        guard let game = HoYoGame.identify(folder: folder) else { return nil }
        self.init(game: game, folder: folder)
    }

    init(game: HoYoGame, folder: URL) {
        self.game = game
        self.folder = folder.standardizedFileURL
    }

    var configFile: URL { folder.appending(path: "config.ini") }

    /// The build the folder holds, from `config.ini`, or nil for a folder no
    /// launcher has written one in.
    var version: String? {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { return nil }
        return Self.value(of: "game_version", in: text)
    }

    /// Records `tag` as the folder's build, keeping every other line of an
    /// existing `config.ini`.
    func recordVersion(_ tag: String) throws {
        let existing = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        try Self.settingVersion(tag, in: existing).write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// `text` with its `game_version` set to `tag`: the line replaced where
    /// there is one, added under `[General]` where there is not.
    static func settingVersion(_ tag: String, in text: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { key(of: $0) == "game_version" }) {
            let ending = lines[index].hasSuffix("\r") ? "\r" : ""
            lines[index] = "game_version=\(tag)\(ending)"
        } else if let general = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[General]") }) {
            lines.insert("game_version=\(tag)", at: general + 1)
        } else {
            lines.insert(contentsOf: ["[General]", "game_version=\(tag)"], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private static func key(of line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return line[..<equals].trimmingCharacters(in: .whitespaces)
    }

    static func value(of wanted: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) where key(of: line) == wanted {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Files

    /// One line of a `pkg_version` file.
    struct Entry: Decodable, Sendable, Equatable {
        let remoteName: String
        let md5: String
        let fileSize: Int64
    }

    /// Every `pkg_version` file in the folder: the game's own and one per
    /// installed voice pack.
    var packageLists: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0 == "pkg_version" || $0.hasSuffix("_pkg_version") }
            .sorted()
            .map { folder.appending(path: $0) }
    }

    /// The files the folder's `pkg_version` lists say it holds.
    func expectedFiles() -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []
        for list in packageLists {
            guard let text = try? String(contentsOf: list, encoding: .utf8) else { continue }
            for entry in Self.entries(in: text) where seen.insert(entry.remoteName).inserted {
                entries.append(entry)
            }
        }
        return entries
    }

    static func entries(in text: String) -> [Entry] {
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(Entry.self, from: Data(line.utf8))
        }
    }

    /// A file of the installation that is missing or not the file it should
    /// be.
    struct Problem: Sendable, Equatable {
        enum Kind: String, Sendable { case missing, size, checksum }
        let path: String
        let kind: Kind
    }

    /// Checks every listed file: that it exists, has its size and, unless
    /// `quick`, its md5. `progress` is called after each file with the bytes
    /// checked so far and the total.
    func verify(
        quick: Bool = false,
        progress: @Sendable (_ done: Int64, _ total: Int64) -> Void = { _, _ in },
    ) -> [Problem] {
        let entries = expectedFiles()
        let total = entries.reduce(0) { $0 + $1.fileSize }
        var done: Int64 = 0
        var problems: [Problem] = []
        for entry in entries {
            defer {
                done += entry.fileSize
                progress(done, total)
            }
            let url = folder.appending(path: entry.remoteName)
            guard let size = Self.size(of: url) else {
                problems.append(Problem(path: entry.remoteName, kind: .missing))
                continue
            }
            guard size == entry.fileSize else {
                problems.append(Problem(path: entry.remoteName, kind: .size))
                continue
            }
            if !quick, (try? SophonCodec.md5(of: url)) != entry.md5 {
                problems.append(Problem(path: entry.remoteName, kind: .checksum))
            }
        }
        return problems
    }

    static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}
