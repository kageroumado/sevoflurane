import AppKit

extension AppDelegate {
    /// Applies the fix list to a game's first launch under Sevoflurane before
    /// its env files are written, and otherwise writes them for the
    /// executables just recorded. Runs on the launch's detached task.
    nonisolated static func prepareLaunch(appID: Int, recordedExecutables: Bool) async {
        guard let fixes = FixLedger.applyAtFirstLaunch(appID: appID) else {
            if recordedExecutables {
                ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
            }
            return
        }
        let name = GameConfig.game(appID).name ?? SharedGames.installed(appID: appID)?.name ?? "App \(appID)"
        await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.announce(fixes, forApp: appID, named: name)
        }
    }

    /// Says what the fix list set: a line in the event log, and a
    /// notification whose Undo puts the game's own settings back.
    private func announce(_ fixes: AppliedFixes, forApp appID: Int, named name: String) {
        let titles = fixes.fixes.map(\.title).joined(separator: ", ")
        let changes = GameConfig.changes(from: fixes.previous, to: fixes.applied).joined(separator: ", ")
        EventLog.shared.log(.app, "fixes: \(name) (\(appID)) first launch took \(titles): \(changes)")
        notifications.postFixesApplied(appID: appID, name: name, settings: fixes.settingNames)
    }
}

extension AppliedFixes {
    /// What the fix list set, one item per setting, in Settings' words.
    var settingNames: [String] {
        applied.fields.keys.sorted().map { key in
            if let id = SettingID(rawValue: key) {
                let setting = SettingCatalog.setting(id)
                if let value = setting.read(applied) {
                    return "\(setting.title): \(setting.label(of: value))"
                }
            }
            if key == "dllOverrides", let table = applied.dllOverrides {
                let libraries = table.keys.sorted().joined(separator: ", ")
                return String(localized: "DLL overrides: \(libraries)")
            }
            return key
        }
    }
}
