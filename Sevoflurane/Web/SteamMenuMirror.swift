import AppKit

/// Steam's in-window menu strip, mirrored one to one into the macOS menu bar.
///
/// All five of the strip's menus exist as hidden popups from the moment the UI
/// boots — `Steam Root Menu` through `Help Root Menu` — with their items
/// already rendered and localized. The mirror reads each popup's DOM through
/// the context page and rebuilds the native menus from it; choosing a native
/// item clicks the corresponding element, which reaches React's root listener
/// even while the element is hidden. The in-window strip itself is hidden by
/// ``SteamDesktopChrome``, so the native menu bar is the only visible strip.
@MainActor
final class SteamMenuMirror: NSObject {
    /// The strip's menus, left to right. Each names a `<title> Root Menu`
    /// popup; the popup indices do not follow this order, so titles are the
    /// join key.
    static let rootTitles = ["Steam", "View", "Friends", "Games", "Help"]

    /// Marks a menu item the mirror must leave alone: the app's own items
    /// appended after the mirrored section.
    static let nativeTag = 1

    /// macOS key equivalents for items Steam gives none, matched on the
    /// item's (English) label.
    private static let keyEquivalents: [String: String] = [
        "Settings": ",",
        "Library": "1",
        "Downloads": "2",
        "Friends & Chat": "3",
    ]

    private weak var host: SteamWebHost?
    private var menus: [String: NSMenu] = [:]
    private var refreshing = false
    private var retriesLeft = 0

    init(host: SteamWebHost) {
        self.host = host
        super.init()
        for title in Self.rootTitles {
            let menu = NSMenu(title: title)
            menu.delegate = self
            // Enablement comes from Steam's own `aria-disabled`, not from the
            // responder chain.
            menu.autoenablesItems = false
            menus[title] = menu
        }
    }

    /// The native menu for one strip title, empty until Steam's UI is up.
    func menu(for title: String) -> NSMenu {
        menus[title]!
    }

    /// Re-reads the strip until all five menus have answered. Popups are
    /// adopted before their titles are set and their items rendered, so the
    /// first reads after boot see an incomplete strip; the retry closes that
    /// gap without an explicit "menus are ready" signal, which Steam does not
    /// send.
    func refresh() {
        retriesLeft = 10
        guard !refreshing else { return }
        refreshing = true
        Task(name: "Refresh menu mirror") {
            defer { refreshing = false }
            while true {
                let complete = await fetchAndApply()
                guard !complete, retriesLeft > 0 else { return }
                retriesLeft -= 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Reading the strip

    private struct MirroredItem: Decodable, Equatable {
        var sep: Bool?
        var label: String?
        var on: Bool?
        var disabled: Bool?
    }

    /// One read of the strip. Answers whether every root menu was present.
    private func fetchAndApply() async -> Bool {
        guard let raw = await host?.evaluateInContext(Self.fetchScript),
              let data = raw.data(using: .utf8),
              let roots = try? JSONDecoder()
              .decode([String: [MirroredItem]].self, from: data) else { return false }
        for (title, items) in roots {
            apply(items, to: menus[title])
        }
        return Self.rootTitles.allSatisfy { !(roots[$0] ?? []).isEmpty }
    }

    private func apply(_ items: [MirroredItem], to menu: NSMenu?) {
        guard let menu, items != current(in: menu) else { return }
        for item in menu.items where item.tag != Self.nativeTag {
            menu.removeItem(item)
        }
        for (childIndex, item) in items.enumerated().reversed() {
            let native: NSMenuItem
            if item.sep == true {
                native = .separator()
            } else {
                let label = item.label ?? ""
                native = NSMenuItem(
                    title: label,
                    action: #selector(activate(_:)),
                    keyEquivalent: Self.keyEquivalents[label] ?? "",
                )
                native.target = self
                native.state = item.on == true ? .on : .off
                native.isEnabled = item.disabled != true
                native.representedObject = childIndex
            }
            menu.insertItem(native, at: 0)
        }
    }

    /// The mirrored section of a menu, re-encoded for change detection —
    /// rebuilding an unchanged menu would flicker while it is open, and
    /// `menuWillOpen` refreshes exactly then.
    private func current(in menu: NSMenu) -> [MirroredItem] {
        menu.items.filter { $0.tag != Self.nativeTag }.map { item in
            item.isSeparatorItem
                ? MirroredItem(sep: true)
                : MirroredItem(
                    label: item.title,
                    on: item.state == .on,
                    disabled: !item.isEnabled,
                )
        }
    }

    private static let fetchScript = """
    (function () {
      var roots = {};
      g_PopupManager.m_mapPopups.forEach(function (v) {
        var title = v.m_strTitle || "";
        if (!/ Root Menu$/.test(title)) return;
        var p = v.m_popup;
        var doc = p && !p.closed && p.document;
        if (!doc || !doc.body) return;
        var el = doc.body;
        while (el && el.children.length === 1) el = el.children[0];
        if (!el) return;
        roots[title.replace(/ Root Menu$/, "")] =
          Array.prototype.map.call(el.children, function (c) {
            if (c.tagName === "HR") return { sep: true };
            return { label: c.textContent.trim(),
                     on: !!c.querySelector("svg, img"),
                     disabled: c.getAttribute("aria-disabled") === "true" };
          });
      });
      return JSON.stringify(roots);
    })()
    """

    // MARK: - Driving the strip

    @objc
    private func activate(_ sender: NSMenuItem) {
        guard let childIndex = sender.representedObject as? Int,
              let rootTitle = sender.menu?.title else { return }
        Task(name: "Dispatch \(rootTitle) ▸ \(sender.title)") {
            _ = await host?.evaluateInContext(
                Self.clickScript(rootTitle: rootTitle, childIndex: childIndex),
            )
        }
    }

    /// Clicks the item's element in the hidden root-menu popup. The index is
    /// the DOM child index (separators included), so the fetched list and the
    /// dispatch can never drift.
    private static func clickScript(rootTitle: String, childIndex: Int) -> String {
        """
        (function () {
          var doc = null;
          g_PopupManager.m_mapPopups.forEach(function (v) {
            if (v.m_strTitle === "\(rootTitle) Root Menu") {
              var p = v.m_popup;
              if (p && !p.closed) doc = p.document;
            }
          });
          if (!doc || !doc.body) return "no popup";
          var el = doc.body;
          while (el && el.children.length === 1) el = el.children[0];
          var item = el && el.children[\(childIndex)];
          if (!item || item.tagName === "HR") return "no item";
          item.click();
          return "clicked";
        })()
        """
    }
}

extension SteamMenuMirror: NSMenuDelegate {
    /// Steam's labels move (`View Friends List (2 Online)`, the status marks),
    /// so every open re-reads the strip. The fetch is asynchronous; a change
    /// lands in the open menu a frame later, and an unchanged menu is left
    /// untouched.
    func menuWillOpen(_: NSMenu) {
        refresh()
    }

    /// Accessibility and keyboard menu access resolve items through
    /// `menuNeedsUpdate` without ever opening the menu. The fetch is
    /// asynchronous, so this answers the *next* query — the mouse path above
    /// has the same shape.
    func menuNeedsUpdate(_: NSMenu) {
        refresh()
    }
}
