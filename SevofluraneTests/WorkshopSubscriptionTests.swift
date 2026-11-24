import Foundation
import Testing
@testable import Sevoflurane

@MainActor
struct WorkshopSubscriptionTests {
    private struct Sender: LinkSender {
        let identifier: String
        func isSigned(as identifier: String) -> Bool { identifier == self.identifier }
    }

    private func request(_ link: String) -> WorkshopSubscription.Request? {
        URL(string: link).flatMap(WorkshopSubscription.Request.init(url:))
    }

    @Test
    func `a companion's link names the companion and the item`() throws {
        let parsed = try #require(request("sevoflurane://workshop/subscribe?app=431960&id=2950163297"))
        #expect(parsed.companion == .wallpaperEngine)
        #expect(parsed.itemID == "2950163297")
        #expect(request("sevoflurane://workshop/subscribe?id=1&app=431960")?.itemID == "1")
        #expect(request("sevoflurane://workshop/subscribe?app=431960&id=" + String(repeating: "9", count: 20)) != nil)
    }

    @Test(arguments: [
        "sevoflurane://workshop/subscribe?app=730&id=1",
        "sevoflurane://workshop/subscribe?app=+431960&id=1",
        "sevoflurane://workshop/subscribe?app=431960",
        "sevoflurane://workshop/subscribe?id=1",
        "sevoflurane://workshop/subscribe?app=431960&id=",
        "sevoflurane://workshop/subscribe?app=431960&id=12a",
        "sevoflurane://workshop/subscribe?app=431960&id=-1",
        "sevoflurane://workshop/subscribe?app=431960&id=%2D1",
        "sevoflurane://workshop/subscribe?app=431960&id=" + String(repeating: "9", count: 21),
        "sevoflurane://workshop/subscribe?app=431960&id=1&id=2",
        "sevoflurane://workshop/subscribe?app=431960&id=1&extra=1",
        "sevoflurane://workshop/unsubscribe?app=431960&id=1",
        "sevoflurane://workshop/subscribe/?app=431960&id=1",
        "sevoflurane://play/subscribe?app=431960&id=1",
        "steam://workshop/subscribe?app=431960&id=1",
        "sevoflurane://workshop/subscribe?app=431960&id=1#x",
        "sevoflurane://user@workshop/subscribe?app=431960&id=1",
        "sevoflurane://workshop:1/subscribe?app=431960&id=1",
    ])
    func `anything else is refused`(link: String) {
        #expect(request(link) == nil)
    }

    @Test
    func `the partner app subscribes silently`() throws {
        let parsed = try #require(request("sevoflurane://workshop/subscribe?app=431960&id=1"))
        let partner = Sender(identifier: "glass.kagerou.phosphene")
        #expect(WorkshopSubscription.decision(for: parsed, sender: partner) == .subscribe)
    }

    @Test
    func `any other sender, or none, is asked first`() throws {
        let parsed = try #require(request("sevoflurane://workshop/subscribe?app=431960&id=1"))
        #expect(WorkshopSubscription.decision(for: parsed, sender: Sender(identifier: "com.apple.Safari")) == .ask)
        #expect(WorkshopSubscription.decision(for: parsed, sender: nil) == .ask)
    }

    @Test
    func `a subscription passes the item id as a string`() {
        let call = SteamSurface.Call.subscribeWorkshopItem.invocation("431960", JSLiteral.string("2950163297"), "true")
        #expect(call == #"SteamClient.Apps.SubscribeWorkshopItem(431960, "2950163297", true)"#)
    }
}
