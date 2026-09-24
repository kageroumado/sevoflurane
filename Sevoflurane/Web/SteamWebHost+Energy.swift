import AppKit

extension SteamWebHost {
    /// Steam's library runs its animated capsule art at 60fps — a steady cost
    /// even when idle. When macOS says the user wants to save power (Low Power
    /// Mode) or reduce motion (the accessibility preference), that cost is
    /// exactly what they are asking to shed, so the matching Steam settings
    /// are turned on to match, and put back when the macOS preference goes
    /// away.
    ///
    /// These are unambiguous system signals — the OS only reports them when the
    /// user has opted in — so this never quiets the UI while they want it full.
    /// The user's own Steam values are captured before the first change and
    /// restored after, persisted across a quit so a launch under Low Power Mode
    /// does not mistake our value for theirs.
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

    /// Applies the current macOS energy/motion preference to Steam. Safe to
    /// call whenever the context page is up — on the notifications, and once
    /// the desktop is adopted so a preference set before launch is honored.
    func updateEnergyPreference() {
        guard context != nil else { return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Passes run one after another: two overlapping passes race over
        // the saved baseline, and the older one can finish last and win.
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
            Preferences.app.removeObject(forKey: Self.renderBaselineKey)
            guard let values = try? JSONDecoder().decode([String: Bool].self, from: Data(baseline.utf8))
            else { return }
            _ = await evaluateInContext(Self.setRenderSettingsScript(
                lowPerf: values["library_low_perf_mode"] ?? false,
                reduceMotion: values["accessibility_reduce_motion"] ?? false,
                smoothScroll: values["smooth_scroll_webviews"] ?? true,
            ))
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
