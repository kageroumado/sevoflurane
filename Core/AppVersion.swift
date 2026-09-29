import Foundation

/// The app's marketing version: as the bundle carries it (`1.0.0-beta.1`, the
/// full semantic version the updater matches against the release's tag and its
/// `Sevoflurane-1.0.0-beta.1.dmg`), as a person reads it ("1.0 beta 1"), and how
/// two of them order.
nonisolated enum AppVersion {
    /// "1.0 beta 1" for `1.0.0-beta.1` and `1.0-beta.1`, "1.2.3 beta 4" for
    /// `1.2.3-beta.4`: a zero patch number is left out. Any other version comes
    /// back as it is.
    static func display(_ version: String) -> String {
        guard let beta = parse(version), let number = beta.beta else { return version }
        var release = beta.release
        if beta.numbers.count == 3, beta.numbers[2] == 0 { release = beta.numbers.prefix(2).map(String.init).joined(separator: ".") }
        return "\(release) beta \(number)"
    }

    /// Whether `lhs` comes before `rhs`. Dotted numbers compare component by
    /// component, a missing trailing component reading as zero, so "1.6"
    /// equals "1.6.0". A beta comes before its release and after the release
    /// that precedes it: `1.0-beta.2` < `1.0` < `1.1-beta.1`. A component that
    /// is not a number counts as zero, which keeps a "dev" or empty version
    /// from ever reading as newer than a numbered release.
    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        let left = parse(lhs) ?? Parsed(release: lhs, numbers: numbers(lhs), beta: nil)
        let right = parse(rhs) ?? Parsed(release: rhs, numbers: numbers(rhs), beta: nil)
        for index in 0 ..< max(left.numbers.count, right.numbers.count) {
            let l = index < left.numbers.count ? left.numbers[index] : 0
            let r = index < right.numbers.count ? right.numbers[index] : 0
            if l != r { return l < r }
        }
        switch (left.beta, right.beta) {
        case let (l?, r?): return l < r
        case (.some, nil): return true
        case (nil, _): return false
        }
    }

    /// The running bundle's marketing version as a person reads it, or
    /// `fallback` when the bundle carries none.
    static func displayed(from info: [String: Any]?, fallback: String) -> String {
        (info?["CFBundleShortVersionString"] as? String).map(display) ?? fallback
    }

    private struct Parsed {
        /// The numeric part, `1.0.0` of `1.0.0-beta.1`.
        let release: String
        let numbers: [Int]
        /// The beta number, `1` of `1.0.0-beta.1`; nil for a release.
        let beta: Int?
    }

    private static func parse(_ version: String) -> Parsed? {
        guard let match = version.wholeMatch(of: /(\d+(?:\.\d+)*)(?:-beta\.(\d+))?/) else { return nil }
        let release = String(match.1)
        return Parsed(release: release, numbers: numbers(release), beta: match.2.flatMap { Int($0) })
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
