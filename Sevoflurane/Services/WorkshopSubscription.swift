import AppKit

/// Subscribes the Steam account to one Workshop item of a companion app
/// (``GameCompanion``) when its partner app asks, through
/// `sevoflurane://workshop/subscribe?app=<appid>&id=<publishedfileid>`.
///
/// Steam downloads the item in the background and the partner watches the
/// download folder, so no window comes forward. Any page or program can open
/// the link, so only the partner itself is served silently; anyone else gets
/// an alert to confirm.
@MainActor
enum WorkshopSubscription {
    /// A parsed `sevoflurane://workshop/subscribe` link.
    nonisolated struct Request: Equatable, Sendable {
        let companion: GameCompanion
        /// The item's published file id, as Steam's own stores hold it.
        let itemID: String

        /// Accepts exactly host `workshop`, path `/subscribe`, and the two
        /// query items `app` (a companion's app id) and `id` (1 to 20 digits).
        init?(url: URL) {
            guard url.scheme?.lowercased() == "sevoflurane", url.host()?.lowercased() == "workshop",
                  url.path() == "/subscribe", url.user() == nil, url.port == nil, url.fragment() == nil,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  items.count == 2,
                  let app = Self.value(of: "app", in: items), Self.isDigits(app, maxLength: Limit.appIDLength),
                  let appID = Int(app), let companion = GameCompanion.all[appID],
                  let itemID = Self.value(of: "id", in: items), Self.isDigits(itemID, maxLength: Limit.itemIDLength)
            else { return nil }
            self.companion = companion
            self.itemID = itemID
        }

        /// The one value named `name`; nil when it is missing or repeated.
        private static func value(of name: String, in items: [URLQueryItem]) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }

        private static func isDigits(_ text: String, maxLength: Int) -> Bool {
            (1 ... maxLength).contains(text.utf8.count) && text.utf8.allSatisfy { (0x30 ... 0x39).contains($0) }
        }
    }

    enum Decision: Equatable {
        case subscribe
        case ask
    }

    nonisolated private enum Limit {
        static let appIDLength = 10
        static let itemIDLength = 20
        /// Characters of a refused link the log keeps.
        static let loggedLinkLength = 200
    }

    /// How long a subscription waits for a client still coming up: a cold
    /// boot takes a minute or two.
    private static let clientBudget = Duration.seconds(300)

    /// Silent for the companion's partner app, an alert for anyone else and
    /// for a sender that could not be identified.
    static func decision(for request: Request, sender: (any LinkSender)?) -> Decision {
        sender?.isSigned(as: request.companion.partnerBundleID) == true ? .subscribe : .ask
    }

    /// Takes a `sevoflurane://workshop` link: subscribes, asks first, or logs
    /// why it did neither.
    static func take(_ url: URL, sender: (any LinkSender)?) {
        guard let request = Request(url: url) else {
            EventLog.shared.log(.client, "Workshop link refused: \(url.absoluteString.prefix(Limit.loggedLinkLength))")
            return
        }
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let what = "\(request.companion.name) Workshop item \(request.itemID)"
        // Steam is held behind an unfinished setup, so the assistant comes up
        // instead.
        if delegate.setupWindow.show() {
            EventLog.shared.log(.window, "\(what) asked for while setup is unfinished — showing setup")
            return
        }
        switch decision(for: request, sender: sender) {
        case .subscribe:
            EventLog.shared.log(.client, "\(what): \(request.companion.partner) asked to subscribe")
            subscribe(request, delegate: delegate)
        case .ask:
            EventLog.shared.log(.client, "\(what): the sender is not \(request.companion.partner)'s signed app, confirming")
            ModalAlerts.present {
                guard confirm(request) else {
                    EventLog.shared.log(.client, "\(what): subscription canceled")
                    return
                }
                subscribe(request, delegate: delegate)
            }
        }
    }

    private static func confirm(_ request: Request) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Subscribe to a \(request.companion.name) Workshop item?")
        alert.informativeText = String(localized: """
        An app asked to subscribe your Steam account to Workshop item \(request.itemID). Steam then downloads it.
        """)
        alert.addButton(withTitle: String(localized: "Subscribe"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Waits for a healthy client, then asks Steam to subscribe.
    private static func subscribe(_ request: Request, delegate: AppDelegate) {
        let what = "\(request.companion.name) Workshop item \(request.itemID)"
        Task(name: "Subscribe to \(what)") {
            let deadline = ContinuousClock.now + clientBudget
            while delegate.supervisor.health != .healthy {
                guard ContinuousClock.now < deadline else {
                    EventLog.shared.log(.client, "\(what): not subscribed, the client never came up")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            let (appID, itemID) = (String(request.companion.appID), JSLiteral.string(request.itemID))
            let call = SteamSurface.Call.subscribeWorkshopItem.invocation(appID, itemID, "true")
            let answer = await delegate.host.evaluateInContext("\(call), \"sent\"")
            EventLog.shared.log(
                .client,
                answer == "sent" ? "\(what): subscription sent to Steam" : "\(what): not subscribed, the page did not answer",
            )
        }
    }
}
