import Foundation

/// The app's marketing version (`1.0.0-beta.1`, which the updater matches
/// against release tags), how a person reads it, and how two order.
nonisolated enum AppVersion {
    /// "1.0 beta 1" for `1.0.0-beta.1`, dropping a zero patch number; any
    /// other version comes back as it is.
    static func display(_ version: String) -> String {
        guard let beta = parse(version), let number = beta.beta else { return version }
        var release = beta.release
        if beta.numbers.count == 3, beta.numbers[2] == 0 { release = beta.numbers.prefix(2).map(String.init).joined(separator: ".") }
        return "\(release) beta \(number)"
    }

    /// Whether `lhs` comes before `rhs`: missing components read as zero ("1.6"
    /// equals "1.6.0"), `1.0-beta.2` < `1.0` < `1.1-beta.1`, and a non-number
    /// such as "dev" reads as zero, never newer than a release.
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

    /// The bundle's version for display, or `fallback`.
    static func displayed(from info: [String: Any]?, fallback: String) -> String {
        (info?["CFBundleShortVersionString"] as? String).map(display) ?? fallback
    }

    private struct Parsed {
        /// `1.0.0` of `1.0.0-beta.1`.
        let release: String
        let numbers: [Int]
        /// `1` of `1.0.0-beta.1`.
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
