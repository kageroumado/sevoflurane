import WebKit

/// Keeps Steam's modal overlay in step with the windows the app tears down.
///
/// A Steam dialog with its own window (`PopupWindow_…`) also pushes an
/// invisible modal into the desktop's modal manager to hold the dimming
/// `FullModalOverlay` up; the overlay goes away only when that modal is
/// removed, which the popup document's `unload` does (`CPopup.OnUnload` runs
/// the modal's `fnOnClose`).
///
/// WebKit delivers no `pagehide` or `unload` on `window.close()`, so the app
/// fires both from the context page, where the popup's `Window` object and
/// Steam's listeners live. This works after the popup's web view is gone,
/// and a second delivery is a no-op.
extension SteamWebHost {
    /// Runs the teardown Steam expects from a closed popup, by name, in the
    /// context page's realm where the listeners live.
    func notifyPopupUnloaded(named name: String) {
        guard !name.isEmpty else { return }
        evaluateInContextPage(Self.popupUnloadScript(popup: name))
    }

    /// Safety net under `notifyPopupUnloaded`: dismisses a modal overlay
    /// that is up, holds no answerable window and paints nothing, through the
    /// manager's own `fnOnClose` and `RemoveModal`.
    func repairStuckModalOverlay() {
        guard let desktopName = desktop?.name, !desktopName.isEmpty else { return }
        Task(name: "Repair stuck modal overlay") { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            let answer = await evaluateInContext(
                Self.overlayRepairScript(desktop: desktopName),
            )
            guard let answer, !answer.isEmpty else { return }
            EventLog.shared.log(.window, "dismissed a modal overlay its popup left up: \(answer)")
        }
    }

    private func evaluateInContextPage(_ script: String) {
        Task(name: "Notify popup unloaded") { [weak self] in
            _ = await self?.evaluateInContext(script)
        }
    }

    private static func popupUnloadScript(popup name: String) -> String {
        """
        (function () {
          try {
            var popups = window.g_PopupManager && g_PopupManager.m_mapPopups;
            var entry = popups && popups.get(\(JSLiteral.string(name)));
            var win = entry && entry.m_popup;
            if (!win) return "absent";
            win.dispatchEvent(new win.Event("pagehide"));
            win.dispatchEvent(new win.Event("unload"));
            return "unloaded";
          } catch (e) {
            return "error: " + e;
          }
        })()
        """
    }

    private static func overlayRepairScript(desktop name: String) -> String {
        """
        (function () {
          try {
            var popups = window.g_PopupManager && g_PopupManager.m_mapPopups;
            var entry = popups && popups.get(\(JSLiteral.string(name)));
            var win = entry && entry.m_popup;
            if (!win || win.closed) return "";
            var overlay = win.document.querySelector(".FullModalOverlay");
            if (!overlay) return "";
            if (win.getComputedStyle(overlay).display === "none") return "";
            var key = Object.keys(overlay).filter(function (k) {
              return k.indexOf("__reactFiber$") === 0;
            })[0];
            var node = key ? overlay[key] : null;
            var manager = null;
            for (var i = 0; node && i < 20; i++) {
              var props = node.memoizedProps;
              if (props && props.ModalManager && props.ModalManager.modals) {
                manager = props.ModalManager;
                break;
              }
              node = node.return;
            }
            if (!manager || !manager.modals.length) return "";
            var answerable = manager.legacy_popup_modals.filter(function (modal) {
              var held = popups.get(modal.name);
              return held && held.m_popup && !held.m_popup.closed;
            });
            if (answerable.length) return "";
            if (overlay.innerText.trim() !== "") return "";
            if (overlay.querySelector("button, a, input, textarea, select")) return "";
            var count = manager.modals.length + manager.legacy_popup_modals.length;
            manager.legacy_popup_modals.slice().forEach(function (modal) {
              var close = modal.options && modal.options.fnOnClose;
              if (typeof close === "function") close();
            });
            manager.modals.slice().forEach(function (modal) {
              manager.RemoveModal(modal);
            });
            return count + " modal(s)";
          } catch (e) {
            return "error: " + e;
          }
        })()
        """
    }
}
