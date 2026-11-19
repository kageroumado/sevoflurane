import AppKit

/// Steam's in-window menu strip, mirrored one to one into the macOS menu bar.
///
/// The strip's five menus exist as hidden popups from the moment the UI boots
/// (`Steam Root Menu` through `Help Root Menu`), already rendered and
/// localized. The mirror reads each popup's DOM through the context page into
/// a cache; choosing a native item clicks the matching element, which reaches
/// React's root listener even while hidden. ``SteamDesktopChrome`` hides the
/// in-window strip.
///
/// **The native menus change in `menuNeedsUpdate(_:)` and nowhere else.**
/// AppKit calls it synchronously just before the menu is shown, the one
/// moment the menu bar (another process holding handles on our items)
/// expects items to move. A menu mutated at any other moment can leave that
/// process waiting on an item that no longer exists, with the app parked
/// inside `NSMenuTrackingSession` and no lever from this side to end it.
///
/// While the section's shape holds (same count, rules in the same places),
/// labels, states and enablement are written into the existing items, so
/// every item keeps its identity; items are rebuilt only when the shape
/// changed.
///
/// The page is read on the events that can change the strip, never from a
/// menu delegate: `menuNeedsUpdate(_:)` must return with the menu populated,
/// and a fetch answers a frame later.
@MainActor
final class SteamMenuMirror: NSObject {
    /// The strip's menus, left to right. Each names a `<title> Root Menu`
    /// popup; the popup indices do not follow this order, so titles are the
    /// join key.
    static let rootTitles = ["Steam", "View", "Friends", "Games", "Help"]

    /// Marks a menu item the mirror must leave alone: the app's own items
    /// appended after the mirrored section.
    static let nativeTag = 1

    /// Marks an item the mirror itself made. The mirrored section is the set
    /// of items carrying this tag rather than a range of positions: AppKit
    /// puts its own search item into the Help menu, and a positional section
    /// would sweep it away on every update and AppKit would put it back. The
    /// value is arbitrary, far from the small integers frameworks use.
    static let mirroredTag = 0x5E70

    /// The single disabled item a title carries until the page has answered
    /// for it. An empty root menu gives the menu-bar agent no window to
    /// display, and a tracking session with nothing on screen cannot be
    /// dismissed.
    static let placeholderTitle = "Steam is starting…"

    /// One item of one root menu, as the page reports it. `sep` marks a rule;
    /// every other field describes a command.
    struct MirroredItem: Decodable, Equatable {
        var sep: Bool?
        var label: String?
        var on: Bool?
        var disabled: Bool?
    }

    /// What one update of a native menu did, for the log and the tests.
    enum Update: Equatable {
        /// The menu already said what the cache says.
        case unchanged(items: Int)
        /// Written into the existing items; every item, and every handle
        /// another process holds on one, survived.
        case patched(items: Int)
        /// The section's shape changed, so its items were replaced. The one
        /// the menu bar can notice.
        case rebuilt(from: Int, to: Int)
    }

    private enum Timing {
        /// Popups are adopted before their titles are set and their items
        /// rendered, so the first reads after boot see an incomplete strip.
        static let retries = 10
        static let retryInterval: Duration = .seconds(1)
        /// Steam moves labels with no signal, so the cache is re-read on this
        /// tick while the app is active.
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
    private var frontmostTick: Timer?
    private let watchdog = MenuTrackingWatchdog()

    init(host: SteamWebHost) {
        self.host = host
        super.init()
        for title in Self.rootTitles {
            let menu = NSMenu(title: title)
            menu.delegate = self
            // Enablement comes from Steam's own `aria-disabled`.
            menu.autoenablesItems = false
            menus[title] = menu
            Self.apply([], to: menu, target: self)
        }
        observeActivation()
        // The watchdog's private stop lever inspects the open menus' tracking
        // sessions, and only the mirror knows which are open.
        watchdog.trackedMenus = { [weak self] in
            guard let self else { return [] }
            return openTitles.compactMap { menus[$0] }
        }
    }

    /// The native menu for one strip title, carrying the placeholder until
    /// Steam's UI is up.
    func menu(for title: String) -> NSMenu {
        menus[title]!
    }

    /// Re-reads the strip into the cache, retrying until all five menus have
    /// answered: Steam sends no signal between a popup's adoption and its
    /// items existing.
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
    /// open: the way out from outside when a stuck session freezes the app
    /// while its control port still answers.
    ///
    /// On macOS 27+ this also pulls the watchdog's private stop lever, so
    /// `POST /menu/cancel` and the Settings button reach the leaked remote
    /// session the public cancel cannot. It runs on the main actor, so it
    /// frees a live freeze only if the tracking loop drains main-queue work;
    /// the watchdog's `.common`-mode probe is the lever relied on. This call
    /// lets a tester fire the lever on demand, and its log lines show whether
    /// it ran during a freeze.
    @discardableResult
    func cancelTracking() -> [String] {
        let open = openTitles.sorted()
        MenuTrackingWatchdog.cancelMenuBarTracking()
        if MenuTrackingWatchdog.privateLeverEngages {
            let candidates = [NSApp.mainMenu].compactMap(\.self) + open.compactMap { menus[$0] }
            let outcome = MenuTrackingWatchdog.stopPrivateSession(candidateMenus: candidates)
            EventLog.shared.log(.menu, "control port /menu/cancel — private lever: \(outcome.summary)")
        }
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
        let moved = Self.merge(roots, into: &model)
        if DebugModeSwitch.shared.isOn {
            for title in moved {
                EventLog.shared.log(
                    .menu,
                    "\(title) cache changed: \(model[title]?.count ?? 0) items — the menu follows at its next update",
                )
            }
        }
        return Self.rootTitles.allSatisfy { !(roots[$0] ?? []).isEmpty }
    }

    /// Takes one page read into the cache, answering the titles whose entries
    /// moved. Never touches a native menu.
    static func merge(
        _ roots: [String: [MirroredItem]], into model: inout [String: [MirroredItem]],
    ) -> [String] {
        var moved: [String] = []
        for title in rootTitles {
            guard let items = roots[title], items != model[title] else { continue }
            model[title] = items
            moved.append(title)
        }
        return moved
    }

    // MARK: - Writing the menus

    /// Brings one title's native menu up to date with the cache, and logs
    /// what that took.
    private func update(_ title: String) {
        guard let menu = menus[title] else { return }
        log(Self.apply(model[title] ?? [], to: menu, target: self), for: title)
    }

    /// A rebuild is always logged: it is rare, and one during a live session
    /// is the first thing to look for when a menu stopped responding.
    /// In-place updates are logged only in debug mode.
    private func log(_ update: Update, for title: String) {
        switch update {
        case let .rebuilt(from, to):
            let live = watchdog.isTracking ? " — a menu session was live" : ""
            EventLog.shared.log(.menu, "\(title) menu rebuilt: \(from) → \(to) items\(live)")
        case let .patched(items):
            guard DebugModeSwitch.shared.isOn else { return }
            EventLog.shared.log(.menu, "\(title) menu patched in place: \(items) items")
        case let .unchanged(items):
            guard DebugModeSwitch.shared.isOn else { return }
            EventLog.shared.log(.menu, "\(title) menu already matched the cache: \(items) items")
        }
    }

    /// Writes `items` into `menu`'s mirrored section, in place while the shape
    /// allows, leaving the app's and AppKit's own items alone. An empty
    /// `items` yields the placeholder.
    @discardableResult
    static func apply(
        _ items: [MirroredItem], to menu: NSMenu, target: AnyObject?,
    ) -> Update {
        let wanted = resolved(items)
        let existing = mirroredItems(in: menu)
        guard sameShape(wanted, as: existing) else {
            // The section keeps its place: in the View menu it sits above the
            // app's own commands, in the Help menu below AppKit's search item.
            let insertion = menu.items.firstIndex { $0.tag == mirroredTag } ?? 0
            for item in existing {
                menu.removeItem(item)
            }
            for native in nativeItems(for: wanted, target: target).reversed() {
                menu.insertItem(native, at: insertion)
            }
            return .rebuilt(from: existing.count, to: wanted.count)
        }
        return patch(existing, to: wanted, target: target)
            ? .patched(items: wanted.count)
            : .unchanged(items: wanted.count)
    }

    /// Whether `items` can be written over `existing` in place: same count,
    /// rules in the same places. Covers Steam's label churn
    /// (`View Friends List (2 Online)`).
    static func sameShape(_ items: [MirroredItem], as existing: [NSMenuItem]) -> Bool {
        items.count == existing.count
            && zip(items, existing).allSatisfy { ($0.sep == true) == $1.isSeparatorItem }
    }

    /// Writes each entry into the item in its place; answers whether any
    /// changed.
    @discardableResult
    static func patch(
        _ existing: [NSMenuItem], to items: [MirroredItem], target: AnyObject?,
    ) -> Bool {
        var moved = false
        for (index, item) in items.enumerated() where item.sep != true {
            let changed = write(item, at: index, into: existing[index], target: target)
            moved = moved || changed
        }
        return moved
    }

    /// The native items one title's cache entry becomes, the placeholder when
    /// the entry is empty.
    static func nativeItems(for items: [MirroredItem], target: AnyObject?) -> [NSMenuItem] {
        resolved(items).enumerated().map { index, item in
            guard item.sep != true else {
                let separator = NSMenuItem.separator()
                separator.tag = mirroredTag
                return separator
            }
            let native = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            native.tag = mirroredTag
            write(item, at: index, into: native, target: target)
            return native
        }
    }

    /// Writes one entry into one native item; answers whether it changed.
    @discardableResult
    private static func write(
        _ item: MirroredItem, at index: Int, into native: NSMenuItem, target: AnyObject?,
    ) -> Bool {
        let label = item.label ?? ""
        let state: NSControl.StateValue = item.on == true ? .on : .off
        let enabled = item.disabled != true
        let keyEquivalent = keyEquivalents[label] ?? ""
        var changed = false
        if native.title != label {
            native.title = label
            changed = true
        }
        if native.state != state {
            native.state = state
            changed = true
        }
        if native.isEnabled != enabled {
            native.isEnabled = enabled
            changed = true
        }
        if native.keyEquivalent != keyEquivalent {
            native.keyEquivalent = keyEquivalent
            changed = true
        }
        if native.representedObject as? Int != index {
            native.representedObject = index
            changed = true
        }
        native.action = #selector(activate(_:))
        native.target = target
        return changed
    }

    /// The items a cache entry stands for: the placeholder when it is empty.
    private static func resolved(_ items: [MirroredItem]) -> [MirroredItem] {
        items.isEmpty ? [placeholderModel] : items
    }

    /// Disabled, so its action is never sent; carrying one lets the first
    /// real item Steam answers with be written straight into it.
    private static let placeholderModel = MirroredItem(
        sep: nil, label: placeholderTitle, on: false, disabled: true,
    )

    /// The section of a menu the mirror owns.
    static func mirroredItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.tag == mirroredTag }
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

    // MARK: - Friends status

    /// One persona state from the Friends menu, with Steam's localized label.
    struct StatusChoice: Equatable {
        let label: String
        /// The DOM child index ``clickScript(rootTitle:childIndex:label:)``
        /// takes.
        let childIndex: Int
        /// The checked state, the one the user is in.
        let isCurrent: Bool
        let isEnabled: Bool
    }

    private static let friendsTitle = "Friends"

    /// Online, Away, Invisible and Offline.
    private static let personaStateCount = 4

    /// The persona states the cached Friends menu offers, in Steam's order;
    /// empty until the page has answered for it.
    var friendsStatuses: [StatusChoice] {
        Self.statusChoices(in: model[Self.friendsTitle] ?? [])
    }

    /// The Friends menu's last group, which Steam builds from the four
    /// persona states. Found by position so it works in every language; a
    /// last group of any other size answers none.
    static func statusChoices(in items: [MirroredItem]) -> [StatusChoice] {
        guard let rule = items.lastIndex(where: { $0.sep == true }) else { return [] }
        let group = items.indices.dropFirst(rule + 1)
        guard group.count == personaStateCount,
              group.allSatisfy({ items[$0].sep != true && !(items[$0].label ?? "").isEmpty })
        else { return [] }
        return group.map { index in
            StatusChoice(
                label: items[index].label ?? "",
                childIndex: index,
                isCurrent: items[index].on == true,
                isEnabled: items[index].disabled != true,
            )
        }
    }

    // MARK: - Refresh triggers

    /// Arms the frontmost tick while the app is active and disarms it
    /// otherwise.
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

    /// Re-reads the cache on a slow tick while the app is in front. The tick
    /// runs in `.common` modes because a menu-bar tracking session runs the
    /// run loop in `NSEventTrackingRunLoopMode`; a read landing mid-tracking
    /// touches only the cache.
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
        dispatch(rootTitle: rootTitle, childIndex: childIndex, label: sender.title)
    }

    /// Chooses one persona state, the way choosing it in the Friends menu
    /// does.
    func setFriendsStatus(_ choice: StatusChoice) {
        dispatch(rootTitle: Self.friendsTitle, childIndex: choice.childIndex, label: choice.label)
    }

    private func dispatch(rootTitle: String, childIndex: Int, label: String) {
        Task(name: "Dispatch \(rootTitle) ▸ \(label)") {
            let outcome = await host?.evaluateInContext(
                Self.clickScript(rootTitle: rootTitle, childIndex: childIndex, label: label),
            )
            if let outcome, outcome != "clicked" {
                EventLog.shared.log(.menu, "\(rootTitle) ▸ \(label) not dispatched: \(outcome)")
            }
        }
    }

    /// Clicks the item's element in the hidden root-menu popup, by the DOM
    /// child index the fetch read it at (separators included). It clicks
    /// only while the text is still `label`, so a strip changed since the
    /// last read answers "moved" instead of running its neighbor.
    static func clickScript(rootTitle: String, childIndex: Int, label: String) -> String {
        """
        (function () {
          var doc = null;
          g_PopupManager.m_mapPopups.forEach(function (v) {
            if (v.m_strTitle === \(JSLiteral.string(rootTitle + " Root Menu"))) {
              var p = v.m_popup;
              if (p && !p.closed) doc = p.document;
            }
          });
          if (!doc || !doc.body) return "no popup";
          var el = doc.body;
          while (el && el.children.length === 1) el = el.children[0];
          var item = el && el.children[\(childIndex)];
          if (!item || item.tagName === "HR") return "no item";
          if (item.textContent.trim() !== \(JSLiteral.string(label))) return "moved";
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
    /// Brings the menu up to date with the cache, synchronously: the menu-bar
    /// agent reads the menu the moment this returns, and an accessibility
    /// query resolves items through it without opening anything. The only
    /// place the mirror changes a menu.
    ///
    /// A title whose shape changed is restructured here even while a session
    /// is live (a menu still showing the placeholder once Steam's UI is up):
    /// the menu being restructured is the one AppKit is about to read, and
    /// the log line notes the live session.
    ///
    /// The lazy protocol (`numberOfItems(in:)` + `menu(_:update:at:shouldCancel:)`)
    /// cannot carry Steam's rules: AppKit materializes plain items for it,
    /// and `NSMenuItem.isSeparatorItem` is read-only.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let title = title(of: menu) else { return }
        update(title)
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
