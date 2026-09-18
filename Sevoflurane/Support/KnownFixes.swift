import Foundation

/// A setting this app knows a particular game wants, and why.
///
/// A fix is a recommendation and never an action: a game that launches fine
/// keeps what it has, and the value only moves when someone presses the chip
/// in Settings. Every entry names what was measured, because the reason is
/// what the user is being asked to judge.
nonisolated struct KnownFix: Sendable, Identifiable {
    /// The Steam app this is about, for a fix that belongs to one game.
    let appID: Int?
    /// A lower-cased executable name, `*` standing for any run of characters,
    /// for a fix that belongs to a shape of game rather than to one.
    let exePattern: String?
    /// The game or family, so a table can be read without looking up app ids.
    let title: String
    /// What to set. Only the keys this fix is about are non-nil.
    let values: ConfigValues
    /// Why — the sentence the chip's tooltip shows.
    let reason: String

    var id: String {
        "\(appID.map(String.init) ?? exePattern ?? "?")/\(title)"
    }

    /// Whether this fix is about `appID`, or about one of the executables the
    /// game is known to run under.
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

/// The per-game quirk table: app id or executable shape to the settings that
/// game wants, with the measurement behind each one.
///
/// The report window reads the same table, so a run that ends badly and the
/// fix for it are one entry.
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

    /// What a named DLL is missing from, and what puts it back: the dependency
    /// package that carries the file, and the load order the game needs so the
    /// installed copy answers rather than Wine's stand-in.
    struct DLLRepair: Sendable {
        /// The ``BottleDependencies`` catalog id.
        let dependency: String
        /// The DLL, lower case and without its extension — the name the
        /// registry's `DllOverrides` takes.
        let dll: String
        /// Wine's load order for it: native first, so the installed file wins
        /// over the prefix's stand-in, with the builtin still behind it.
        let mode = "n,b"

        /// The package as Settings names it.
        var packageName: String {
            BottleDependencies.catalog.first { $0.id == dependency }?.name ?? dependency
        }

        var reason: String {
            "\(dll).dll comes with \(packageName); installing it and taking the native "
                + "copy for this game is what the missing-DLL error asks for."
        }
    }

    /// What to offer for a DLL a run said was missing — `0xc0000135`, a
    /// loader line naming the file, "X.dll was not found".
    ///
    /// Winetricks is the reference for which package carries which file; the
    /// matching is the family a name belongs to, since these ship as numbered
    /// series a game picks one member of.
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

    /// The 140-family files the evergreen Visual C++ redistributable lays
    /// down — the same list its install writes overrides for.
    private static let vcRuntimeDLLs: Set<String> = [
        "concrt140", "msvcp140", "msvcp140_1", "msvcp140_2",
        "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcamp140",
        "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1",
    ]

    /// The numbered families the June 2010 DirectX redistributable carries:
    /// the D3DX helper libraries, the XInput pads, and the XACT and XAudio
    /// sound engines.
    private static let directXPrefixes = [
        "d3dx9_", "d3dx10_", "d3dx11_", "d3dcompiler_4",
        "xinput1_", "xaudio2_", "x3daudio1_", "xactengine",
    ]

    /// Folds a repair into a game's own values: the load order for that one
    /// DLL, over whatever the bottle says.
    static func apply(_ repair: DLLRepair, to values: inout ConfigValues) {
        var table = values.dllOverrides ?? [:]
        table[repair.dll] = repair.mode
        values.dllOverrides = table
    }

    /// What the table says about this game: the keys every matching entry
    /// sets, and the entries themselves so a control can show the reason
    /// behind the key it is about.
    static func recommended(for appID: Int, exes: [String] = []) -> Recommendation {
        Recommendation(fixes: all.filter { $0.matches(appID: appID, exes: exes) })
    }

    /// What the table says about a game, read one key at a time.
    struct Recommendation: Sendable {
        let fixes: [KnownFix]

        var isEmpty: Bool {
            fixes.isEmpty
        }

        /// Every reason, for a report that lists them.
        var reasons: [String] {
            fixes.map(\.reason)
        }

        /// The entry that recommends a value for `key`, if one does.
        func fix(setting key: KeyPath<ConfigValues, (some Any)?>) -> KnownFix? {
            fixes.first { $0.values[keyPath: key] != nil }
        }

        /// The recommended value for `key`, if the table has one.
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
                    merged.dllOverrides = (merged.dllOverrides ?? [:]).merging(overrides) {
                        _, new in new
                    }
                }
                if let hud = fix.values.hud { merged.hud = hud }
                if let large = fix.values.largeAddressAware { merged.largeAddressAware = large }
                if let avx = fix.values.avx { merged.avx = avx }
                if let confine = fix.values.cursorConfine { merged.cursorConfine = confine }
                if let runner = fix.values.runner { merged.runner = runner }
            }
            return merged
        }
    }
}
