import WebKit

/// Keeps Steam's modal overlay in step with the windows the app tears down.
///
/// A Steam dialog that gets its own window is two objects, not one. The
/// content goes into a popup (`PopupWindow_…`), and a second, invisible modal
/// is pushed into the desktop's own modal manager to hold the dimming overlay
/// up while the dialog is answered. The desktop's `FullModalOverlay` carries
/// `display: none` exactly while that manager's modal list is empty, so the
/// library behind it comes back only when the invisible modal is removed.
///
/// What removes it is the popup document's `unload` event: `CPopup.OnUnload`
/// stops tracking the popup, runs the modal's `fnOnClose`, and that closes the
/// invisible modal. Under CEF that event is the popup window closing. Here it
/// is the page teardown that follows the web view being released, which is a
/// different thing and lands whenever the app lets go — measured on a popup
/// closed the way Steam closes one, `window.close()` set `closed` to true on
/// the opener's handle and delivered no `pagehide` and no `unload` at all.
/// The dialog leaves the screen, the overlay stays, and the library sits
/// behind a scrim that nothing can dismiss.
///
/// So the app fires those two events itself, from the context page, which is
/// where the popup's `Window` object and Steam's listeners both live. It works
/// after the popup's web view is already gone, because the context page holds
/// the object either way, and a second delivery is a no-op because the first
/// clears the popup Steam would act on.
extension SteamWebHost {
    /// Runs the teardown Steam expects from a popup whose window has closed.
    ///
    /// Addressed by popup name rather than by web view: the events have to be
    /// dispatched in the context page's realm, where the listeners were
    /// registered.
    func notifyPopupUnloaded(named name: String) {
        guard !name.isEmpty else { return }
        evaluateInContextPage(Self.popupUnloadScript(popup: name))
    }

    /// Dismisses a modal overlay left standing over the desktop after the
    /// popup that owned it went away.
    ///
    /// A safety net under `notifyPopupUnloaded`, for the case where Steam's
    /// own teardown ran but left the invisible modal behind anyway. It fires
    /// only on an overlay that is up, holds no window the user could answer,
    /// and paints nothing — and it dismisses through the modal manager's own
    /// `fnOnClose` and `RemoveModal`, so Steam's bookkeeping stays true.
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
