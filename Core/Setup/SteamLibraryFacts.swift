import Foundation

/// What tells one Steam installation from another to the person who plays
/// in it: how many games it holds, when one was last played, and what they
/// take on disk. Read from the app manifests Steam keeps beside its games.
nonisolated struct SteamLibraryFacts: Equatable, Sendable {
    var games = 0
    var lastPlayed: Date?
    var bytes: Int64 = 0

    /// Reads `steamapps/appmanifest_*.acf` under a Steam folder. Games in
    /// library folders on other disks are not counted.
    static func read(steamRoot: URL) -> SteamLibraryFacts {
        let apps = steamRoot.appendingPathComponent("steamapps")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []
        var facts = SteamLibraryFacts()
        for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            guard let text = try? String(contentsOf: apps.appendingPathComponent(name), encoding: .utf8)
            else { continue }
            facts.add(manifest: text)
        }
        return facts
    }

    /// Counts one manifest: its `SizeOnDisk` and its `LastPlayed`.
    mutating func add(manifest text: String) {
        games += 1
        bytes += Self.number(named: "SizeOnDisk", in: text) ?? 0
        if let seconds = Self.number(named: "LastPlayed", in: text), seconds > 0 {
            let played = Date(timeIntervalSince1970: TimeInterval(seconds))
            lastPlayed = max(lastPlayed ?? played, played)
        }
    }

    /// The value of `"key"  "123"` in a manifest's text.
    private static func number(named key: String, in text: String) -> Int64? {
        guard let range = text.range(of: "\"\(key)\"") else { return nil }
        let digits = text[range.upperBound...]
            .prefix { !$0.isNewline }
            .drop { !$0.isNumber }
            .prefix(while: \.isNumber)
        return Int64(digits)
    }
}
