import AppKit

extension SteamWebHost {
    /// Under Low Power Mode or Reduce Motion, Steam's matching rendering
    /// settings are turned on (its animated capsule art runs at 60fps even
    /// idle), and put back when the preference goes. The user's own values
    /// are saved before the first change, persisted across a quit so a launch
    /// under Low Power Mode does not take our values for theirs.
    private static let renderBaselineKey = "sevo.renderSettingsBaseline"

    func installEnergyPreferenceMirror() {
        for name in [
            NSNotification.Name.NSProcessInfoPowerStateDidChange,
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        ] {
            let center: NotificationCenter = name == .NSProcessInfoPowerStateDidChange
                ? .default : NSWorkspace.shared.notificationCenter
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.updateEnergyPreference() }
                }
            }
        }
    }

    /// Applies the current macOS energy/motion preference to Steam.
    func updateEnergyPreference() {
        guard context != nil else { return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Serialized: overlapping passes race over the saved baseline.
        let previous = energyUpdate
        energyUpdate = Task(name: "Match Steam's rendering to macOS") {
            await previous?.value
            await applyEnergyPreference(lowPower: lowPower, reduceMotion: reduceMotion)
        }
    }

    private func applyEnergyPreference(lowPower: Bool, reduceMotion: Bool) async {
        if lowPower || reduceMotion {
            if Preferences.app.string(forKey: Self.renderBaselineKey) == nil {
                guard let saved = await evaluateInContext(Self.captureRenderSettingsScript),
                      saved != "unavailable" else { return }
                Preferences.app.set(saved, forKey: Self.renderBaselineKey)
            }
            _ = await evaluateInContext(Self.setRenderSettingsScript(
                lowPerf: lowPower, reduceMotion: true, smoothScroll: !lowPower,
            ))
            EventLog.shared.log(
                .app,
                "matched macOS power preference (low power=\(lowPower), reduce motion=\(reduceMotion)) — eased Steam's rendering",
            )
        } else if let baseline = Preferences.app.string(forKey: Self.renderBaselineKey) {
            guard let values = try? JSONDecoder().decode([String: Bool].self, from: Data(baseline.utf8)) else {
                Preferences.app.removeObject(forKey: Self.renderBaselineKey)
                return
            }
            // The baseline goes only once Steam took it back: a page that is
            // not ready keeps it for the next pass.
            let restored = await evaluateInContext(Self.setRenderSettingsScript(
                lowPerf: values["library_low_perf_mode"] ?? false,
                reduceMotion: values["accessibility_reduce_motion"] ?? false,
                smoothScroll: values["smooth_scroll_webviews"] ?? true,
            ))
            guard restored == "ok" else {
                EventLog.shared.log(.app, "restoring Steam's rendering failed (\(restored ?? "no answer")) — kept for the next pass")
                return
            }
            Preferences.app.removeObject(forKey: Self.renderBaselineKey)
            EventLog.shared.log(.app, "macOS power preference cleared — restored Steam's rendering")
        }
    }

    private static let captureRenderSettingsScript = """
    (function () {
      var s = window.settingsStore;
      if (!s || typeof s.GetClientSetting !== "function") return "unavailable";
      function g(k) { var v = s.GetClientSetting(k); return Array.isArray(v) ? !!v[0] : !!v; }
      return JSON.stringify({
        library_low_perf_mode: g("library_low_perf_mode"),
        accessibility_reduce_motion: g("accessibility_reduce_motion"),
        smooth_scroll_webviews: g("smooth_scroll_webviews"),
      });
    })()
    """

    private static func setRenderSettingsScript(
        lowPerf: Bool, reduceMotion: Bool, smoothScroll: Bool,
    ) -> String {
        """
        (function () {
          var a = window.SteamClient && SteamClient.Settings;
          if (!a || typeof a.SetSetting !== "function") return "unavailable";
          a.SetSetting("library_low_perf_mode", \(lowPerf));
          a.SetSetting("accessibility_reduce_motion", \(reduceMotion));
          a.SetSetting("smooth_scroll_webviews", \(smoothScroll));
          return "ok";
        })()
        """
    }
}
