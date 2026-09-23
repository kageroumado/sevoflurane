import AppKit
import Testing
@testable import Sevoflurane

@MainActor
struct SteamMenuMirrorTests {
    private typealias Item = SteamMenuMirror.MirroredItem

    private func command(_ label: String, on: Bool = false, disabled: Bool = false) -> Item {
        Item(sep: nil, label: label, on: on, disabled: disabled)
    }

    private func rootMenu(_ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        return menu
    }

    @Test
    func `an empty model still yields one disabled item`() {
        let items = SteamMenuMirror.nativeItems(for: [], target: nil)
        #expect(items.count == 1)
        #expect(items[0].title == SteamMenuMirror.placeholderTitle)
        #expect(!items[0].isEnabled)
        #expect(items[0].tag == SteamMenuMirror.mirroredTag)
    }

    @Test
    func `every model item becomes one native item, separators included`() {
        let model = [command("Library"), Item(sep: true), command("Downloads")]
        let items = SteamMenuMirror.nativeItems(for: model, target: nil)
        #expect(items.count == 3)
        #expect(items[0].title == "Library")
        #expect(items[1].isSeparatorItem)
        #expect(items[2].title == "Downloads")
        #expect(items.allSatisfy { $0.tag == SteamMenuMirror.mirroredTag })
    }

    @Test
    func `state, enablement, key equivalent and dispatch index carry over`() {
        let model = [command("Settings"), command("Big Picture Mode", on: true, disabled: true)]
        let items = SteamMenuMirror.nativeItems(for: model, target: nil)
        #expect(items[0].keyEquivalent == ",")
        #expect(items[0].representedObject as? Int == 0)
        #expect(items[0].state == NSControl.StateValue.off)
        #expect(items[0].isEnabled)
        #expect(items[1].state == NSControl.StateValue.on)
        #expect(!items[1].isEnabled)
        #expect(items[1].representedObject as? Int == 1)
    }

    @Test
    func `a separator keeps its dispatch index in the items after it`() {
        let model = [command("Library"), Item(sep: true), command("Downloads")]
        let items = SteamMenuMirror.nativeItems(for: model, target: nil)
        #expect(items[2].representedObject as? Int == 2)
    }

    @Test
    func `applying a model never leaves a menu empty`() {
        let menu = rootMenu("Steam")
        for model in [[command("Library")], [], [command("A"), Item(sep: true), command("B")], []] {
            SteamMenuMirror.apply(model, to: menu, target: nil)
            #expect(menu.numberOfItems > 0)
        }
        #expect(menu.numberOfItems == 1)
        #expect(menu.item(at: 0)?.title == SteamMenuMirror.placeholderTitle)
    }

    @Test
    func `applying a model leaves the app's own items alone`() {
        let menu = rootMenu("View")
        let native = NSMenuItem(title: "Reload Steam UI", action: nil, keyEquivalent: "r")
        native.tag = SteamMenuMirror.nativeTag
        menu.addItem(native)

        SteamMenuMirror.apply([command("Library")], to: menu, target: nil)
        #expect(menu.numberOfItems == 2)
        #expect(menu.item(at: 0)?.title == "Library")
        #expect(menu.item(at: 1) === native)

        SteamMenuMirror.apply([], to: menu, target: nil)
        #expect(menu.numberOfItems == 2)
        #expect(menu.item(at: 0)?.title == SteamMenuMirror.placeholderTitle)
        #expect(menu.item(at: 1) === native)
    }

    /// AppKit puts its own search item into the Help menu. It carries no tag
    /// of ours, it is not the mirror's to move, and the mirrored section goes
    /// under it and stays there.
    @Test
    func `applying a model leaves AppKit's own items alone, and keeps its place under them`() {
        let menu = rootMenu("Help")
        SteamMenuMirror.apply([command("Steam Support")], to: menu, target: nil)
        let search = NSMenuItem(title: "Search", action: nil, keyEquivalent: "")
        menu.insertItem(search, at: 0)

        let update = SteamMenuMirror.apply(
            [command("Steam Support"), command("Steam News")], to: menu, target: nil,
        )
        #expect(update == .rebuilt(from: 1, to: 2))
        #expect(menu.numberOfItems == 3)
        #expect(menu.item(at: 0) === search)
        #expect(menu.item(at: 1)?.title == "Steam Support")
        #expect(menu.item(at: 2)?.title == "Steam News")
    }

    @Test
    func `a model the menu already shows changes nothing`() {
        let menu = rootMenu("Games")
        let model = [command("Activate a Product on Steam…")]
        SteamMenuMirror.apply(model, to: menu, target: nil)
        let first = menu.item(at: 0)

        #expect(SteamMenuMirror.apply(model, to: menu, target: nil) == .unchanged(items: 1))
        #expect(menu.item(at: 0) === first)
    }

    /// The label churn Steam actually produces — `View Friends List (2 Online)`
    /// and the status marks — must not cost the menu its items: the menu bar
    /// is another process holding handles on them.
    @Test
    func `a same-shape model is written into the items the menu already has`() {
        let menu = rootMenu("Friends")
        let before = [
            command("View Friends List (2 Online)"),
            Item(sep: true),
            command("Offline", on: true),
        ]
        SteamMenuMirror.apply(before, to: menu, target: nil)
        let items = menu.items

        let update = SteamMenuMirror.apply(
            [
                command("View Friends List (3 Online)"),
                Item(sep: true),
                command("Offline", on: false, disabled: true),
            ],
            to: menu, target: nil,
        )

        #expect(update == .patched(items: 3))
        #expect(menu.items.map { ObjectIdentifier($0) } == items.map { ObjectIdentifier($0) })
        #expect(menu.item(at: 0)?.title == "View Friends List (3 Online)")
        #expect(menu.item(at: 2)?.state == NSControl.StateValue.off)
        #expect(menu.item(at: 2)?.isEnabled == false)
    }

    @Test
    func `a model with a rule in a new place is a structural rebuild`() {
        let menu = rootMenu("View")
        SteamMenuMirror.apply([command("A"), Item(sep: true), command("B")], to: menu, target: nil)
        let update = SteamMenuMirror.apply(
            [command("A"), command("B"), Item(sep: true)], to: menu, target: nil,
        )
        #expect(update == .rebuilt(from: 3, to: 3))
    }

    @Test
    func `the shape test counts items and places rules`() {
        let menu = rootMenu("Steam")
        SteamMenuMirror.apply([command("A"), Item(sep: true)], to: menu, target: nil)
        let existing = SteamMenuMirror.mirroredItems(in: menu)
        #expect(SteamMenuMirror.sameShape([command("Z"), Item(sep: true)], as: existing))
        #expect(!SteamMenuMirror.sameShape([command("Z")], as: existing))
        #expect(!SteamMenuMirror.sameShape([Item(sep: true), command("Z")], as: existing))
    }

    /// The placeholder is one item with no rule, so Steam's first answer of
    /// one item reaches the user without the menu being restructured.
    @Test
    func `the placeholder becomes the first real item in place`() {
        let menu = rootMenu("Games")
        SteamMenuMirror.apply([], to: menu, target: nil)
        let placeholder = menu.item(at: 0)

        let update = SteamMenuMirror.apply([command("Library")], to: menu, target: nil)
        #expect(update == .patched(items: 1))
        #expect(menu.item(at: 0) === placeholder)
        #expect(menu.item(at: 0)?.title == "Library")
        #expect(menu.item(at: 0)?.isEnabled == true)
    }

    @Test
    func `a page read that changes the cache leaves the menus untouched`() {
        let menu = rootMenu("Friends")
        var model: [String: [Item]] = ["Friends": [command("View Friends List (2 Online)")]]
        SteamMenuMirror.apply(model["Friends"] ?? [], to: menu, target: nil)
        let items = menu.items

        let moved = SteamMenuMirror.merge(
            ["Friends": [command("View Friends List (3 Online)"), command("Add a Friend…")]],
            into: &model,
        )

        #expect(moved == ["Friends"])
        #expect(model["Friends"]?.count == 2)
        #expect(menu.items.map { ObjectIdentifier($0) } == items.map { ObjectIdentifier($0) })
        #expect(menu.item(at: 0)?.title == "View Friends List (2 Online)")
    }

    @Test
    func `a page read that says nothing new leaves the cache alone`() {
        var model: [String: [Item]] = ["Games": [command("Library")]]
        #expect(SteamMenuMirror.merge(["Games": [command("Library")]], into: &model).isEmpty)
        #expect(SteamMenuMirror.merge([:], into: &model).isEmpty)
    }

    @Test
    func `a menu click runs only while the item still carries its label`() {
        let script = SteamMenuMirror.clickScript(rootTitle: "Games", childIndex: 3, label: #"Say "hi""#)
        #expect(script.contains(#"item.textContent.trim() !== "Say \"hi\"") return "moved";"#))
        #expect(script.contains(#"v.m_strTitle === "Games Root Menu""#))
        #expect(script.contains("el.children[3]"))
    }
}
