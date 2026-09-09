import AppKit

/// Steam's in-window menu strip, mirrored one to one into the macOS menu bar.
///
/// All five of the strip's menus exist as hidden popups from the moment the UI
/// boots — `Steam Root Menu` through `Help Root Menu` — with their items
/// already rendered and localized. The mirror reads each popup's DOM through
/// the context page into a cache, and rebuilds the native menus from that
/// cache; choosing a native item clicks the corresponding element, which
/// reaches React's root listener even while the element is hidden. The
/// in-window strip itself is hidden by ``SteamDesktopChrome``, so the native
/// menu bar is the only visible strip.
///
/// The page is read on the events that can change the strip and never from a
/// menu delegate: `menuNeedsUpdate(_:)` must leave the menu populated before
/// it returns, and a fetch that answers a frame later cannot. Rebuilding from
/// the cache is synchronous, always finishes before the menu-bar agent looks,
/// and always yields at least one item.
@MainActor
final class SteamMenuMirror: NSObject {
    /// The strip's menus, left to right. Each names a `<title> Root Menu`
    /// popup; the popup indices do not follow this order, so titles are the
    /// join key.
    static let rootTitles = ["Steam", "View", "Friends", "Games", "Help"]

    /// Marks a menu item the mirror must leave alone: the app's own items
    /// appended after the mirrored section.
    static let nativeTag = 1

    /// The single disabled item a title carries until the page has answered
    /// for it. A root menu with no items gives the menu-bar agent no menu
    /// window to display, and a tracking session with nothing on screen has
    /// nothing to dismiss.
    static let placeholderTitle = "Steam is starting…"

    /// One item of one root menu, as the page reports it. `sep` marks a rule;
    /// every other field describes a command.
    struct MirroredItem: Decodable, Equatable {
        var sep: Bool?
        var label: String?
        var on: Bool?
        var disabled: Bool?
    }

    private enum Timing {
        /// Popups are adopted before their titles are set and their items
        /// rendered, so the first reads after boot see an incomplete strip.
        static let retries = 10
        static let retryInterval: Duration = .seconds(1)
        /// Steam moves labels (`View Friends List (2 Online)`, the status
        /// marks) with no signal to subscribe to, so the cache is re-read on a
        /// slow tick for as long as the user is in the app.
        static let frontmostInterval: TimeInterval = 30
    }

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
    private var model: [String: [MirroredItem]] = [:]
    private var refreshing = false
    private var retriesLeft = 0
    private var openTitles: Set<String> = []
    private var rebuildDeferred = false
    private var frontmostTick: Timer?
    private let watchdog = MenuTrackingWatchdog()

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
            Self.rebuild(menu, from: [], target: self)
        }
        observeActivation()
        watchdog.onTrackingEnded = { [weak self] in
            guard let self, rebuildDeferred else { return }
            rebuildIdleMenus()
        }
    }

    /// The native menu for one strip title, carrying the placeholder until
    /// Steam's UI is up.
    func menu(for title: String) -> NSMenu {
        menus[title]!
    }

    /// Re-reads the strip into the cache, retrying until all five menus have
    /// answered. The retry closes the gap between a popup being adopted and
    /// its items existing, which Steam sends no signal for.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        retriesLeft = Timing.retries
        Task(name: "Refresh menu mirror") {
            defer { refreshing = false }
            while true {
                let complete = await fetch()
                guard !complete, retriesLeft > 0 else { return }
                retriesLeft -= 1
                try? await Task.sleep(for: Timing.retryInterval)
            }
        }
    }

    /// Ends any menu-bar tracking session and answers which root menus were
    /// open. A stuck session leaves the app looking frozen while its control
    /// port still answers, so this is the way out from outside.
    @discardableResult
    func cancelTracking() -> [String] {
        let open = openTitles.sorted()
        MenuTrackingWatchdog.cancelMenuBarTracking()
        return open
    }

    // MARK: - Reading the strip

    /// One read of the strip into the cache. Answers whether every root menu
    /// was present.
    private func fetch() async -> Bool {
        guard let raw = await host?.evaluateInContext(Self.fetchScript),
              let data = raw.data(using: .utf8),
              let roots = try? JSONDecoder()
              .decode([String: [MirroredItem]].self, from: data) else { return false }
        var changed = false
        for title in Self.rootTitles {
            guard let items = roots[title], items != model[title] else { continue }
            model[title] = items
            changed = true
        }
        if changed { rebuildIdleMenus() }
        return Self.rootTitles.allSatisfy { !(roots[$0] ?? []).isEmpty }
    }

    /// Pushes cache changes into the native menus, skipping the push while a
    /// tracking session is up: removing a menu's items out from under the
    /// menu-bar agent is what leaves it opening a menu that no longer has
    /// anything to show. The gate is the watchdog's run-loop probe rather than
    /// `menuWillOpen`/`menuDidClose`, which report a menu closed while the
    /// agent goes on tracking it.
    private func rebuildIdleMenus() {
        guard !watchdog.isTracking else {
            rebuildDeferred = true
            return
        }
        rebuildDeferred = false
        for title in Self.rootTitles {
            rebuild(title)
        }
    }

    private func rebuild(_ title: String) {
        guard let menu = menus[title] else { return }
        let before = menu.numberOfItems
        Self.rebuild(menu, from: model[title] ?? [], target: self)
        guard before != menu.numberOfItems else { return }
        EventLog.shared.log(
            .menu, "\(title) menu rebuilt: \(before) → \(menu.numberOfItems) items",
        )
    }

    /// Replaces `menu`'s mirrored section with `items`, leaving items tagged
    /// ``nativeTag`` — the app's own commands — where they are. An empty
    /// `items` yields the placeholder, so the rebuilt menu is never empty.
    static func rebuild(_ menu: NSMenu, from items: [MirroredItem], target: AnyObject?) {
        let wanted = items.isEmpty ? [placeholderModel] : items
        guard wanted != mirrored(in: menu) else { return }
        for item in menu.items where item.tag != nativeTag {
            menu.removeItem(item)
        }
        for native in nativeItems(for: items, target: target).reversed() {
            menu.insertItem(native, at: 0)
        }
    }

    /// The native items one title's cache entry becomes, the placeholder when
    /// the entry is empty.
    static func nativeItems(for items: [MirroredItem], target: AnyObject?) -> [NSMenuItem] {
        guard !items.isEmpty else { return [placeholderItem()] }
        return items.enumerated().map { childIndex, item in
            guard item.sep != true else { return .separator() }
            let label = item.label ?? ""
            let native = NSMenuItem(
                title: label,
                action: #selector(activate(_:)),
                keyEquivalent: keyEquivalents[label] ?? "",
            )
            native.target = target
            native.state = item.on == true ? .on : .off
            native.isEnabled = item.disabled != true
            native.representedObject = childIndex
            return native
        }
    }

    private static let placeholderModel = MirroredItem(
        sep: nil, label: placeholderTitle, on: false, disabled: true,
    )

    private static func placeholderItem() -> NSMenuItem {
        let item = NSMenuItem(title: placeholderTitle, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The mirrored section of a menu, re-encoded so a rebuild that would
    /// change nothing can be skipped — every open of every title asks for one,
    /// and the strip mostly stands still.
    private static func mirrored(in menu: NSMenu) -> [MirroredItem] {
        menu.items.filter { $0.tag != nativeTag }.map { item in
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

    // MARK: - Refresh triggers

    /// Arms and disarms the frontmost tick, which only earns its wakeups while
    /// someone is looking at the app.
    private func observeActivation() {
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateFrontmostTick() }
            }
        }
    }

    /// Steam moves its labels under the app, so the cache is re-read on a slow
    /// tick while the app is in front. The tick runs in `.common` modes: a
    /// menu-bar tracking session runs the run loop in
    /// `NSEventTrackingRunLoopMode`, where a `.default`-mode timer would stop,
    /// and a read landing mid-tracking is harmless because
    /// ``rebuildIdleMenus()`` holds the push back.
    private func updateFrontmostTick() {
        guard NSApp.isActive else {
            frontmostTick?.invalidate()
            frontmostTick = nil
            return
        }
        guard frontmostTick == nil else { return }
        let tick = Timer(timeInterval: Timing.frontmostInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(tick, forMode: .common)
        frontmostTick = tick
        refresh()
    }

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

    private func title(of menu: NSMenu) -> String? {
        menus.first { $0.value === menu }?.key
    }
}

extension SteamMenuMirror: NSMenuDelegate {
    /// Rebuilds the menu from the cache, synchronously, which is the contract:
    /// the menu-bar agent reads the menu the moment this returns, and an
    /// accessibility query resolves items through it without opening anything.
    ///
    /// The lazy protocol (`numberOfItems(in:)` + `menu(_:update:at:shouldCancel:)`)
    /// would be the better shape for a strip this size, but it cannot express
    /// this one: AppKit materializes plain items for it to configure, and
    /// `NSMenuItem.isSeparatorItem` is read-only, so the rules Steam puts
    /// between its groups have nowhere to go.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let title = title(of: menu) else { return }
        rebuild(title)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let title = title(of: menu) else { return }
        openTitles.insert(title)
        watchdog.menuOpened()
        EventLog.shared.log(.menu, "\(title) menu opened with \(menu.numberOfItems) items")
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let title = title(of: menu) else { return }
        openTitles.remove(title)
        EventLog.shared.log(.menu, "\(title) menu closed with \(menu.numberOfItems) items")
    }
}
