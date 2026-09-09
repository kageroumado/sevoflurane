import AppKit
import Testing
@testable import Sevoflurane

@MainActor
struct SteamMenuMirrorTests {
    private typealias Item = SteamMenuMirror.MirroredItem

    private func command(_ label: String, on: Bool = false, disabled: Bool = false) -> Item {
        Item(sep: nil, label: label, on: on, disabled: disabled)
    }

    @Test
    func `an empty model still yields one disabled item`() {
        let items = SteamMenuMirror.nativeItems(for: [], target: nil)
        #expect(items.count == 1)
        #expect(items[0].title == SteamMenuMirror.placeholderTitle)
        #expect(!items[0].isEnabled)
        #expect(items[0].action == nil)
    }

    @Test
    func `every model item becomes one native item, separators included`() {
        let model = [command("Library"), Item(sep: true), command("Downloads")]
        let items = SteamMenuMirror.nativeItems(for: model, target: nil)
        #expect(items.count == 3)
        #expect(items[0].title == "Library")
        #expect(items[1].isSeparatorItem)
        #expect(items[2].title == "Downloads")
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
    func `rebuilding a menu never leaves it empty`() {
        let menu = NSMenu(title: "Steam")
        menu.autoenablesItems = false
        for model in [[command("Library")], [], [command("A"), Item(sep: true), command("B")], []] {
            SteamMenuMirror.rebuild(menu, from: model, target: nil)
            #expect(menu.numberOfItems > 0)
        }
        #expect(menu.numberOfItems == 1)
        #expect(menu.item(at: 0)?.title == SteamMenuMirror.placeholderTitle)
    }

    @Test
    func `rebuilding leaves the app's own items alone`() {
        let menu = NSMenu(title: "View")
        menu.autoenablesItems = false
        let native = NSMenuItem(title: "Reload Steam UI", action: nil, keyEquivalent: "r")
        native.tag = SteamMenuMirror.nativeTag
        menu.addItem(native)

        SteamMenuMirror.rebuild(menu, from: [command("Library")], target: nil)
        #expect(menu.numberOfItems == 2)
        #expect(menu.item(at: 0)?.title == "Library")
        #expect(menu.item(at: 1) === native)

        SteamMenuMirror.rebuild(menu, from: [], target: nil)
        #expect(menu.numberOfItems == 2)
        #expect(menu.item(at: 0)?.title == SteamMenuMirror.placeholderTitle)
        #expect(menu.item(at: 1) === native)
    }

    @Test
    func `an unchanged model leaves the existing items in place`() {
        let menu = NSMenu(title: "Games")
        menu.autoenablesItems = false
        let model = [command("Activate a Product on Steam…")]
        SteamMenuMirror.rebuild(menu, from: model, target: nil)
        let first = menu.item(at: 0)
        SteamMenuMirror.rebuild(menu, from: model, target: nil)
        #expect(menu.item(at: 0) === first)
    }
}
