import AppKit

extension AppDelegate {
    /// Readies a launch the app is about to hand to Steam
    /// (``LaunchPreparation``) and says what a first launch's fixes set.
    nonisolated static func prepareLaunch(appID: Int) async {
        let fixes = await LaunchPreparation.prepare(appID: appID) { EventLog.enqueue(.client, $0) }
        guard let fixes else { return }
        await announce(fixes, forApp: appID)
    }

    /// Says what the fix list set at a first launch the helper prepared:
    /// the helper wrote the log line, and the notification is this app's.
    func announceFixesApplied(appID: Int) {
        guard let fixes = FixLedger.record(for: appID) else { return }
        notifications.postFixesApplied(appID: appID, name: Self.name(ofApp: appID), settings: fixes.settingNames)
    }

    private nonisolated static func announce(_ fixes: AppliedFixes, forApp appID: Int) async {
        let name = name(ofApp: appID)
        EventLog.enqueue(.app, fixes.logLine(appID: appID, name: name))
        await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.notifications
                .postFixesApplied(appID: appID, name: name, settings: fixes.settingNames)
        }
    }

    private nonisolated static func name(ofApp appID: Int) -> String {
        GameConfig.game(appID).name ?? SharedGames.installed(appID: appID)?.name ?? "App \(appID)"
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
