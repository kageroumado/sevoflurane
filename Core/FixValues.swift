import Foundation

/// The check every fix from outside this build passes, key by key, before it
/// is offered or applied: the served list is input from the network, and a
/// value it carries ends up in a game's env file and the bottle's registry.
///
/// ``admitted(_:)`` is what the list may recommend: an allow-list of keys,
/// each value checked against what this version reads. ``automatic(_:)`` is
/// the smaller part a first launch applies without a click.
nonisolated enum FixValues {
    /// The load orders Wine's `DllOverrides` takes, in the registry's spelling.
    static let dllModes: Set<String> = ["n,b", "b,n", "n", "b", ""]

    /// The keys of `values` a fix may carry, each with a value this version
    /// reads; everything else is dropped. Enum keys arrive decoded, so an
    /// unknown case has already failed the whole entry.
    static func admitted(_ values: ConfigValues) -> ConfigValues {
        var out = ConfigValues.empty
        if let renderer = values.renderer, renderer != .auto { out.renderer = renderer }
        out.windows = values.windows
        out.mouse = values.mouse
        out.filter = values.filter
        if let tuning = values.tuning, tuning != .custom { out.tuning = tuning }
        if let upscaler = values.upscaler, isValidUpscaler(upscaler) { out.upscaler = upscaler }
        out.emulateModeset = values.emulateModeset
        out.hud = values.hud
        out.fps = values.fps
        out.overlayDetail = values.overlayDetail
        out.frameRateLimit = values.frameRateLimit
        out.largeAddressAware = values.largeAddressAware
        out.avx = values.avx
        out.unifiedMemory = values.unifiedMemory
        out.cursorConfine = values.cursorConfine
        if let processors = values.processors, processorRange.contains(processors) { out.processors = processors }
        if let runner = values.runner, GameRunner.all.contains(runner) { out.runner = runner }
        let overrides = (values.dllOverrides ?? [:]).filter { isValidDLL($0.key) && dllModes.contains($0.value) }
        out.dllOverrides = overrides.isEmpty ? nil : overrides
        let environment = (values.environment ?? [:])
            .filter { UserEnvironment.problem(name: $0.key, value: $0.value) == nil }
        out.environment = environment.isEmpty ? nil : environment
        return out
    }

    /// What a first launch applies of `values` without a click: the admitted
    /// keys less the native runner, which fetches a runtime before it can run
    /// anything, and less any variable that steers the loader, Wine or this
    /// app's own wiring or that names a path. Those stay one-click
    /// recommendations.
    static func automatic(_ values: ConfigValues) -> ConfigValues {
        var out = admitted(values)
        out.runner = nil
        let environment = (out.environment ?? [:]).filter { isAutomaticEnvironment(name: $0.key, value: $0.value) }
        out.environment = environment.isEmpty ? nil : environment
        return out
    }

    /// The processor counts a game can be told of; `0` is every processor.
    static let processorRange = 0 ... 256

    /// A DLL as `DllOverrides` names it: lower case, digits, `_`, `.`, `-`.
    static func isValidDLL(_ name: String) -> Bool {
        name.count <= 64 && name != "." && name != ".."
            && name.wholeMatch(of: /[a-z0-9_.\-]+/) != nil
    }

    /// One of the built-in choices, or a shader package's name: a word of
    /// letters, digits and `._+()-` and spaces, never a path.
    static func isValidUpscaler(_ value: String) -> Bool {
        UpscalerChoice(rawValue: value) != nil
            || (value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9 ._+()\-]{0,63}/) != nil && !value.contains(".."))
    }

    /// Whether a variable may be set without a click: one stored as a
    /// person's own could be, and the name is none of the loader's (`DYLD_`,
    /// `LD_`), Wine's (`WINE`) or this app's (`SEVO_`), and the value names no
    /// path.
    static func isAutomaticEnvironment(name: String, value: String) -> Bool {
        let upper = name.uppercased()
        return UserEnvironment.problem(name: name, value: value) == nil
            && !automaticEnvironmentPrefixes.contains { upper.hasPrefix($0) }
            && !isPathShaped(value)
    }

    private static let automaticEnvironmentPrefixes = ["DYLD_", "LD_", "WINE", "SEVO_"]

    /// A value that reads as a file or folder: a separator of either system,
    /// a home or parent reference, or a drive letter.
    static func isPathShaped(_ value: String) -> Bool {
        value.contains("/") || value.contains("\\") || value.hasPrefix("~") || value.contains("..")
            || value.prefixMatch(of: /[A-Za-z]:/) != nil
    }

    // MARK: - The entry around the values

    /// A lower-case executable name, `*` for any run of characters.
    static func isValidExePattern(_ pattern: String) -> Bool {
        pattern.wholeMatch(of: /[a-z0-9*][a-z0-9 ._()*+\-]{0,63}/) != nil
    }

    /// A title or reason as one plain line: control and format characters,
    /// line breaks included, become spaces, runs of spaces fold, and the
    /// text stops at `limit` characters. The text reaches the event log, a
    /// notification and Settings, none of which it may add a line to.
    static func plainLine(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: " "
            default: Character(scalar)
            }
        }
        let folded = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(folded.prefix(limit))
    }
}
