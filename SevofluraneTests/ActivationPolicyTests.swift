import AppKit
import Testing
@testable import Sevoflurane

@MainActor
struct ActivationPolicyTests {
    /// A window the test owns outright: AppKit releases a window it closes,
    /// and one ARC also holds is then released twice.
    private func makeWindow(_ frame: NSRect, styleMask: NSWindow.StyleMask) -> NSWindow {
        let window = NSWindow(
            contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test
    func `a titled window on screen keeps the Dock tile`() {
        let window = makeWindow(
            NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled, .closable],
        )
        window.orderFront(nil)
        defer { window.close() }

        #expect(ActivationPolicy.keepsTheDockTile(window))
        #expect(!ActivationPolicy.isTheLastWindow(closing: nil, among: [window]))
        #expect(ActivationPolicy.isTheLastWindow(closing: window, among: [window]))
    }

    /// The menu-bar item's own window is in `NSApp.windows`, is visible, at
    /// full alpha, no panel, and sits on a screen — every test the app used to
    /// make. Counting it kept the Dock tile for the life of the process,
    /// because nothing ever closes it.
    @Test
    func `the menu bar status item does not keep the Dock tile`() throws {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let window = try #require(item.button?.window)

        #expect(window.isVisible)
        #expect(window.alphaValue > 0)
        #expect(!(window is NSPanel))
        #expect(!ActivationPolicy.keepsTheDockTile(window))
        #expect(ActivationPolicy.isTheLastWindow(closing: nil, among: [window]))
    }

    @Test
    func `a menu held at alpha 0 does not keep the Dock tile`() {
        let menu = makeWindow(
            NSRect(x: 100, y: 100, width: 200, height: 300), styleMask: [.borderless],
        )
        menu.alphaValue = 0
        menu.orderFront(nil)
        defer { menu.close() }

        #expect(ActivationPolicy.isTheLastWindow(closing: nil, among: [menu]))
    }

    @Test
    func `the parked context page does not keep the Dock tile`() {
        let page = makeWindow(.zero, styleMask: [.borderless])
        page.alphaValue = 0
        page.orderBack(nil)
        defer { page.close() }

        #expect(ActivationPolicy.isTheLastWindow(closing: nil, among: [page]))
    }

    @Test
    func `a second window open keeps the Dock tile as the first one closes`() {
        let settings = makeWindow(
            NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled, .closable],
        )
        let steam = makeWindow(
            NSRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.titled, .closable],
        )
        settings.orderFront(nil)
        steam.orderFront(nil)
        defer {
            settings.close()
            steam.close()
        }

        #expect(!ActivationPolicy.isTheLastWindow(closing: steam, among: [settings, steam]))
    }
}
