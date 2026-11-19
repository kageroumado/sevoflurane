import Foundation

/// A setting this app knows a particular game wants, and why.
///
/// A fix is applied once, at the game's first launch, only to keys the game
/// has no value for (``FixLedger``), with an undo; after that it is a chip in
/// Settings. Every reason names what was measured, because the user judges it.
nonisolated struct KnownFix: Equatable, Sendable, Identifiable {
    /// The Steam app this is about, for a fix that belongs to one game.
    let appID: Int?
    /// A lower-cased executable name with `*` wildcards, for a fix that
    /// belongs to a family of games.
    let exePattern: String?
    let title: String
    /// Only the keys this fix is about are non-nil.
    let values: ConfigValues
    /// The chip's tooltip.
    let reason: String

    var id: String {
        "\(appID.map(String.init) ?? exePattern ?? "?")/\(title)"
    }

    func matches(appID: Int, exes: [String]) -> Bool {
        if let own = self.appID, own == appID { return true }
        guard let exePattern else { return false }
        return exes.contains { Self.matches(pattern: exePattern, name: $0.lowercased()) }
    }

    /// `*` stands for any run of characters; everything else is literal.
    static func matches(pattern: String, name: String) -> Bool {
        let parts = pattern.lowercased().components(separatedBy: "*")
        guard parts.count > 1 else { return pattern.lowercased() == name }
        var rest = Substring(name)
        guard rest.hasPrefix(parts[0]) else { return false }
        rest = rest.dropFirst(parts[0].count)
        for part in parts.dropFirst().dropLast() {
            guard let found = rest.range(of: part) else { return false }
            rest = rest[found.upperBound...]
        }
        return rest.hasSuffix(parts[parts.count - 1])
    }
}

/// The per-game quirk table. ``all`` is the table this app ships;
/// ``recommended(for:exes:)`` reads it together with the community database's
/// list (``FixList``). The report window reads the same table.
nonisolated enum KnownFixes {
    static let all: [KnownFix] = [
        KnownFix(
            appID: 1_962_700, exePattern: nil, title: "Subnautica 2",
            values: ConfigValues(renderer: .d3dmetal),
            reason: "Subnautica 2 renders with Direct3D 12, and D3DMetal is the only "
                + "layer here that answers it.",
        ),
        KnownFix(
            appID: 339_800, exePattern: nil, title: "HuniePop",
            values: ConfigValues(emulateModeset: true),
            reason: "Without faked mode changes the game is offered the display's 16:9 "
                + "modes alone; with them win32u adds 26 virtual modes, the 4:3 ones "
                + "this game looks for included.",
        ),
        KnownFix(
            appID: 310_360, exePattern: nil, title: "Higurashi When They Cry Hou - Ch.1 Onikakushi",
            values: ConfigValues(processors: 8),
            reason: "Unity 5 starts a worker per processor and keeps every one spinning under "
                + "Rosetta: on a 16-core M4 Max the game used 1357 % CPU at 54 fps, stalling "
                + "several times a second, and told of 8 processors, 184 % at 117 fps.",
        ),
        KnownFix(
            appID: 1_933_660, exePattern: nil, title: "Demons Roots",
            values: ConfigValues(runner: GameRunner.nwjs),
            reason: "An RPG Maker MV game on NW.js: the native macOS runtime runs it "
                + "outside the bottle, with its achievements carried by a stub.",
        ),
        KnownFix(
            appID: nil, exePattern: "nw.exe", title: "NW.js games",
            values: ConfigValues(runner: GameRunner.nwjs),
            reason: "The game is NW.js: the native macOS runtime runs it outside the "
                + "bottle, at the speed of a Mac browser rather than of Rosetta.",
        ),
    ]

    // MARK: - A missing DLL

    /// The dependency package that carries a missing DLL, and the load order
    /// that makes the installed copy win over Wine's stand-in.
    struct DLLRepair: Sendable {
        /// The ``BottleDependencies`` catalog id.
        let dependency: String
        /// Lower case without extension, as `DllOverrides` names it.
        let dll: String
        /// Native first, with the builtin behind it.
        let mode = "n,b"

        var packageName: String {
            BottleDependencies.catalog.first { $0.id == dependency }?.name ?? dependency
        }
    }

    /// What to offer for a DLL a run said was missing (`0xc0000135`, a loader
    /// line, "X.dll was not found"). Matches by family, following Winetricks,
    /// since these ship as numbered series.
    static func dllRepair(for missingDLL: String) -> DLLRepair? {
        let dll = missingDLL.lowercased()
            .replacingOccurrences(of: ".dll", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !dll.isEmpty else { return nil }
        if vcRuntimeDLLs.contains(dll) {
            return DLLRepair(dependency: "vcredist", dll: dll)
        }
        if dll == "d3dcompiler_47" {
            return DLLRepair(dependency: "d3dcompiler", dll: dll)
        }
        if directXPrefixes.contains(where: dll.hasPrefix) {
            return DLLRepair(dependency: "directx2010", dll: dll)
        }
        return nil
    }

    /// The files the Visual C++ 140 redistributable installs and writes overrides for.
    private static let vcRuntimeDLLs: Set<String> = [
        "concrt140", "msvcp140", "msvcp140_1", "msvcp140_2",
        "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcamp140",
        "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1",
    ]

    /// The numbered families the June 2010 DirectX redistributable carries.
    private static let directXPrefixes = [
        "d3dx9_", "d3dx10_", "d3dx11_", "d3dcompiler_4",
        "xinput1_", "xaudio2_", "x3daudio1_", "xactengine",
    ]

    /// Sets the repair's load order in a game's own values, over the bottle's.
    static func apply(_ repair: DLLRepair, to values: inout ConfigValues) {
        var table = values.dllOverrides ?? [:]
        table[repair.dll] = repair.mode
        values.dllOverrides = table
    }

    /// Every matching entry, so a control can show the reason behind its key.
    static func recommended(for appID: Int, exes: [String] = []) -> Recommendation {
        recommended(for: appID, exes: exes, from: FixList.current)
    }

    static func recommended(for appID: Int, exes: [String] = [], from table: [KnownFix]) -> Recommendation {
        Recommendation(fixes: table.filter { $0.matches(appID: appID, exes: exes) })
    }

    /// What the table says about a game, read one key at a time.
    struct Recommendation: Sendable {
        let fixes: [KnownFix]

        var isEmpty: Bool {
            fixes.isEmpty
        }

        func fix(setting key: KeyPath<ConfigValues, (some Any)?>) -> KnownFix? {
            fixes.first { $0.values[keyPath: key] != nil }
        }

        func value<Value>(for key: KeyPath<ConfigValues, Value?>) -> Value? {
            fix(setting: key)?.values[keyPath: key]
        }

        /// Every recommended key folded onto `values`, for "Use every
        /// recommendation".
        func applied(to values: ConfigValues) -> ConfigValues {
            var merged = values
            for fix in fixes.reversed() {
                if let renderer = fix.values.renderer { merged.renderer = renderer }
                if let windows = fix.values.windows { merged.windows = windows }
                if let mouse = fix.values.mouse { merged.mouse = mouse }
                if let upscaler = fix.values.upscaler { merged.upscaler = upscaler }
                if let filter = fix.values.filter { merged.filter = filter }
                if let retina = fix.values.retina { merged.retina = retina }
                if let modeset = fix.values.emulateModeset { merged.emulateModeset = modeset }
                if let overrides = fix.values.dllOverrides {
                    merged.dllOverrides = (merged.dllOverrides ?? [:]).merging(overrides) { _, new in new }
                }
                if let hud = fix.values.hud { merged.hud = hud }
                if let large = fix.values.largeAddressAware { merged.largeAddressAware = large }
                if let avx = fix.values.avx { merged.avx = avx }
                if let confine = fix.values.cursorConfine { merged.cursorConfine = confine }
                if let processors = fix.values.processors { merged.processors = processors }
                if let runner = fix.values.runner { merged.runner = runner }
            }
            return merged
        }
    }
}
