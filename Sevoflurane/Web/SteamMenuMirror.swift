import AppKit

/// Steam's in-window menu strip, mirrored one to one into the macOS menu bar.
///
/// All five of the strip's menus exist as hidden popups from the moment the UI
/// boots — `Steam Root Menu` through `Help Root Menu` — with their items
/// already rendered and localized. The mirror reads each popup's DOM through
/// the context page into a cache; choosing a native item clicks the
/// corresponding element, which reaches React's root listener even while the
/// element is hidden. The in-window strip itself is hidden by
/// ``SteamDesktopChrome``, so the native menu bar is the only visible strip.
///
/// **The native menus change in `menuNeedsUpdate(_:)` and nowhere else.** A
/// read of the page updates the cache and stops there; AppKit calls
/// `menuNeedsUpdate(_:)` synchronously in the instant before the menu is
/// shown, and that is the one moment at which the menu bar — which on recent
/// macOS is another process holding handles on our items — expects the items
/// to move. A menu mutated at any other moment can leave that process waiting
/// on an item that no longer exists, with the app parked inside
/// `NSMenuTrackingSession` and no lever from this side that ends it.
///
/// Inside that window the mirror still prefers the smallest change it can
/// make: while the section's shape holds — same count, rules in the same
/// places — labels, states and enablement are written into the items the menu
/// already has, so every item keeps its identity. Items are removed and
/// re-inserted only when the shape itself changed.
///
/// The page is read on the events that can change the strip and never from a
/// menu delegate: `menuNeedsUpdate(_:)` must leave the menu populated before
/// it returns, and a fetch that answers a frame later cannot.
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
    /// of items carrying this tag, not a range of positions: AppKit puts its
    /// own search item into the Help menu, and a section defined by position
    /// would sweep that item away on every update and AppKit would put it
    /// back — a structural change to a menu, twice, every time Help opens.
    /// The value is arbitrary and far from the small integers a framework
    /// hands out, so ownership stays a question with one answer.
    static let mirroredTag = 0x5E70

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

    /// What one update of a native menu did, which is what the log says and
    /// what the tests assert on.
    enum Update: Equatable {
        /// The menu already said what the cache says.
        case unchanged(items: Int)
        /// Written into the items the menu already had; every item, and every
        /// handle another process holds on one, survived.
        case patched(items: Int)
        /// The section's shape changed, so its items were removed and new ones
        /// inserted. The expensive one, and the one the menu bar can notice.
        case rebuilt(from: Int, to: Int)
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
            Self.apply([], to: menu, target: self)
        }
        observeActivation()
        // The watchdog's private stop lever inspects the open menus' tracking
        // sessions; the mirror is the one place that knows which are open.
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
    ///
    /// On macOS 27+ this also pulls the watchdog's private stop lever, so
    /// `POST /menu/cancel` and the Settings button reach the leaked remote
    /// session the public cancel cannot. This runs on the main actor, so it
    /// can only free a live freeze if the tracking loop is draining main-queue
    /// work — the same property the watchdog's `.common`-mode probe relies on,
    /// and the reason that probe, not this call, is the lever we count on. Its
    /// value here is external: it lets a tester fire the lever on demand, and
    /// its log lines say whether the handler ran during a freeze at all.
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

    /// One read of the strip into the cache, which is all it touches. Answers
    /// whether every root menu was present.
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
    /// moved. Nothing here can reach a native menu, which is the point: the
    /// strip is read on a timer, on activation and on every popup adoption,
    /// and a menu changed at one of those moments is a menu changed behind
    /// the menu bar's back.
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

    /// Brings one title's native menu up to date with the cache, and says in
    /// the log what that took.
    private func update(_ title: String) {
        guard let menu = menus[title] else { return }
        log(Self.apply(model[title] ?? [], to: menu, target: self), for: title)
    }

    /// A structural rebuild is always written down — it is rare, and a
    /// rebuild that happened while a session was live is the first thing to
    /// look for in a report of a menu that stopped responding. The in-place
    /// updates are the normal case and are written down only in debug mode.
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
    /// allows it, leaving the app's own items and AppKit's own alone. An empty
    /// `items` yields the placeholder, so the menu is never left empty.
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

    /// Whether `items` can be written over `existing` with nothing added,
    /// removed or reordered: the counts match and the rules fall in the same
    /// places. Steam's own churn is labels — `View Friends List (2 Online)`,
    /// the status marks — which this covers.
    static func sameShape(_ items: [MirroredItem], as existing: [NSMenuItem]) -> Bool {
        items.count == existing.count
            && zip(items, existing).allSatisfy { ($0.sep == true) == $1.isSeparatorItem }
    }

    /// Writes each cache entry into the item already standing in its place,
    /// answering whether any of them moved.
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

    /// Everything one cache entry says about one native item, answering
    /// whether any of it differed from what the item already said.
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

    /// The placeholder is disabled, so the action it carries with every other
    /// mirrored item is never sent. Carrying one is what lets the first real
    /// item Steam answers with be written straight into it.
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

    /// One persona state as the Friends menu offers it: Steam's label, in
    /// Steam's language, and where the strip holds it.
    struct StatusChoice: Equatable {
        let label: String
        /// The DOM child index ``clickScript(rootTitle:childIndex:label:)``
        /// takes.
        let childIndex: Int
        /// Whether this is the state the user is in: Steam marks it with a
        /// check.
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
    /// persona states. It is found by position so it reads the same in every
    /// language Steam speaks; a last group of any other size is some other
    /// menu, and answers none.
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
    /// and a read landing mid-tracking touches nothing but the cache.
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

    /// Clicks the item's element in the hidden root-menu popup. The index is
    /// the DOM child index (separators included), the one the fetch read the
    /// item at; the element is clicked only while its text is still `label`,
    /// so a strip Steam changed since the last read answers "moved" instead
    /// of running its neighbor.
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
    /// Brings the menu up to date with the cache, synchronously, which is the
    /// contract: the menu-bar agent reads the menu the moment this returns,
    /// and an accessibility query resolves items through it without opening
    /// anything. It is also the only place the mirror changes a menu.
    ///
    /// A title whose shape changed is restructured here even while a session
    /// is live — a menu still carrying the placeholder when Steam's UI comes
    /// up is the case, and the alternative is showing the user a menu that
    /// says `Steam is starting…` after it has started. The menu being
    /// restructured is the one AppKit is about to read, which is what makes
    /// this moment the safe one; the log line says a session was live so a
    /// report can be read against it.
    ///
    /// The lazy protocol (`numberOfItems(in:)` + `menu(_:update:at:shouldCancel:)`)
    /// would be the better shape for a strip this size, but it cannot express
    /// this one: AppKit materializes plain items for it to configure, and
    /// `NSMenuItem.isSeparatorItem` is read-only, so the rules Steam puts
    /// between its groups have nowhere to go.
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
