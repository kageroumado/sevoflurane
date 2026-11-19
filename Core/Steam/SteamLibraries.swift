import Foundation

/// Steam's game libraries: the one inside its install and any folder added in
/// Steam › Settings › Storage. `steamapps/libraryfolders.vdf` records them as
/// Windows paths (`C:\Program Files (x86)\Steam`,
/// `Z:\Volumes\Games\SteamLibrary`), each with its own `steamapps`.
nonisolated enum SteamLibraries {
    /// Every library's `steamapps` that exists on disk, the install's own
    /// first; a disconnected drive's library is left out.
    static func steamapps(
        steamRoot: URL = SteamBottle.steamRoot,
        resolve: (String) -> URL? = SteamBottle.macURL(fromWindowsPath:),
    ) -> [URL] {
        let main = steamRoot.appendingPathComponent("steamapps")
        var result = [main]
        var seen: Set<String> = [main.standardizedFileURL.path]
        let text = (try? String(
            contentsOf: main.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8,
        )) ?? ""
        for path in paths(inLibraryFolders: text) {
            guard let root = resolve(path) else { continue }
            let steamapps = root.appendingPathComponent("steamapps")
            guard seen.insert(steamapps.standardizedFileURL.path).inserted,
                  FileManager.default.fileExists(atPath: steamapps.path) else { continue }
            result.append(steamapps)
        }
        return result
    }

    /// The library paths in a `libraryfolders.vdf`, unescaped, in file order,
    /// from either a `"path"` key in each numbered block or the older
    /// numbered key whose value is the path.
    static func paths(inLibraryFolders text: String) -> [String] {
        let quoted = #""((?:[^"\\]|\\.)*)""#
        let current = try? NSRegularExpression(pattern: #""path"\s+"# + quoted)
        let older = try? NSRegularExpression(pattern: #""\d+"[ \t]+"# + quoted)
        let range = NSRange(text.startIndex..., in: text)
        var found: [(offset: Int, path: String)] = []
        for expression in [current, older].compactMap(\.self) {
            for match in expression.matches(in: text, range: range) {
                guard let value = Range(match.range(at: 1), in: text) else { continue }
                found.append((match.range.location, unescape(String(text[value]))))
            }
        }
        // The numbered-key pattern also matches `apps` blocks (app id → size),
        // so only drive or POSIX paths count.
        return found.sorted { $0.offset < $1.offset }.map(\.path).filter(isPath)
    }

    private static func isPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
    }

    /// VDF escapes a backslash as two.
    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: #"\\"#, with: #"\"#)
            .replacingOccurrences(of: #"\""#, with: "\"")
    }

    // MARK: - The drive a library is on

    /// A library drive's file system, as far as Wine cares.
    enum FileSystem: Equatable, Sendable {
        /// APFS or Mac OS Extended.
        case mac
        /// exFAT, FAT or NTFS: no Unix permissions or symbolic links, which
        /// Wine's prefix and some games need. NTFS is also read-only without a
        /// third-party driver.
        case foreign(String)
        /// Steam's updates and Wine's file locking both handle these poorly.
        case network(String)
        case unknown
    }

    static func fileSystem(at url: URL) -> FileSystem {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return .unknown }
        let name = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return fileSystem(named: name)
    }

    static func fileSystem(named name: String) -> FileSystem {
        switch name.lowercased() {
        case "apfs", "hfs": .mac
        case "exfat": .foreign("exFAT")
        case "msdos": .foreign("FAT")
        case "ntfs", "ufsd_ntfs", "tuxera_ntfs": .foreign("NTFS")
        case "smbfs", "afpfs", "nfs", "webdav": .network(name.uppercased())
        default: .unknown
        }
    }
}
