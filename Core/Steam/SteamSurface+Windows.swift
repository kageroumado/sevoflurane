import Foundation

/// Steam's windows as the app hosts them: the popup names it opens, the
/// `SteamClient.Window` calls each popup makes, and the browser views and
/// messages that pass between Steam's page and its host.
nonisolated extension SteamSurface {
    /// A `SteamClient.Window` method the app answers for the window that
    /// called it (`SteamWindow.perform`).
    enum WindowCall: String, CaseIterable, Sendable {
        case showWindow = "ShowWindow"
        case setKeyFocus = "SetKeyFocus"
        case markLastFocused = "MarkLastFocused"
        case setForegroundWindow = "SetForegroundWindow"
        case bringToFront = "BringToFront"
        case hideWindow = "HideWindow"
        case close = "Close"
        case minimize = "Minimize"
        case toggleMaximize = "ToggleMaximize"
        case toggleFullScreen = "ToggleFullScreen"
        case moveTo = "MoveTo"
        case moveToLocation = "MoveToLocation"
        case resizeTo = "ResizeTo"
        case positionWindowRelative = "PositionWindowRelative"
        case setMinSize = "SetMinSize"
        case setMaxSize = "SetMaxSize"
        case setHideOnClose = "SetHideOnClose"
        case setWindowFlashing = "SetWindowFlashing"
        case isWindowMinimized = "IsWindowMinimized"
        case isWindowMaximized = "IsWindowMaximized"
        case getWindowDimensions = "GetWindowDimensions"
        case getWindowDetails = "GetWindowDetails"
        case getDefaultMonitorDimensions = "GetDefaultMonitorDimensions"
        case getMousePositionDetails = "GetMousePositionDetails"
        case defaultMonitorHasFullscreenWindow = "DefaultMonitorHasFullscreenWindow"
        case getWindowRestoreDetails = "GetWindowRestoreDetails"

        /// Window-manager calls with no AppKit counterpart, answered with
        /// nothing: compositing, the gamepad display scale, a window icon.
        static let unanswered = [
            "ProcessShuttingDown", "RestoreWindowSizeAndPosition", "SetComposition",
            "SetGamepadUIAutoDisplayScale", "SetGamepadUIManualDisplayScaleFactor", "SetModal",
            "SetResizeGrip", "SetWindowIcon",
        ]
    }

    /// The name Steam opens a popup under, which decides the window the app
    /// gives it (`SteamWindowRole`). A name ending in `_` or carrying no
    /// separator is the start of a longer one.
    enum Popup: String, CaseIterable, Sendable {
        case desktop = "SP Desktop"
        case bigPicture = "SP BPM"
        case login = "SP DesktopLoginWindow"
        case keyboard = "SP Keyboard"
        case controllerConfigurator = "SP Controller Configurator"
        case contextMenu = "contextmenu_"
        case friendsList = "friendslist"
        case chat = "chat_"
        case notificationToasts = "notificationtoasts"
        case desktopOverlay = "desktopoverlay"
        case gamepadOverlay = "gamepadoverlay"
        case popupWindow = "PopupWindow_"

        /// Whether the popup's name is exactly this, or only begins with it.
        var isWholeName: Bool {
            switch self {
            case .desktop, .bigPicture, .login, .keyboard, .controllerConfigurator: true
            case .contextMenu, .friendsList, .chat, .notificationToasts, .desktopOverlay, .gamepadOverlay,
                 .popupWindow: false
            }
        }

        var use: String {
            switch self {
            case .desktop: "the main window"
            case .bigPicture: "the Big Picture window"
            case .login: "the sign-in window"
            case .keyboard: "the on-screen keyboard's panel"
            case .controllerConfigurator: "the controller configurator's window"
            case .contextMenu: "menus, as panels that take no focus"
            case .friendsList: "the friends list's window"
            case .chat: "chat windows"
            case .notificationToasts: "Steam's own toasts, which stay hidden"
            case .desktopOverlay, .gamepadOverlay: "the in-game overlay's panel"
            case .popupWindow: "dialogs, placed by the app"
            }
        }

        /// How Steam's scripts write the name.
        fileprivate var needle: String {
            switch self {
            case .friendsList, .notificationToasts, .desktopOverlay, .gamepadOverlay: rawValue
            default: "\"\(rawValue)\""
            }
        }
    }

    /// The marker between a popup's name and its instance number.
    static let popupInstanceMarker = "_uid"

    /// What a root menu's popup is titled after the menu's own name.
    static let rootMenuTitleSuffix = " Root Menu"

    /// The message a host posts to a popup once its window exists; Steam
    /// renders nothing into the popup before it.
    static let popupCreatedMessage = "popup-created"

    /// The message a host posts to a popup after its window changed size.
    static let windowResizedMessage = "window_resized"

    /// The path of the client's protobuf transport socket, which only the
    /// client's own context may open.
    static let transportSocketPath = "/transportsocket/"

    /// The origin CEF gives the client's UI.
    static let loopbackHost = "steamloopback.host"

    /// The browser-view methods the shim's view object has.
    static let browserViewMethods = [
        "LoadURL", "ReplaceURL", "Reload", "GoBack", "GoForward", "SetVisible", "SetBounds", "GetBounds",
        "SetFocus", "CanGoBackward", "CanGoForward", "PostMessage", "Destroy",
    ]

    /// The browser-view methods the shim answers with nothing: stacking
    /// order, glass, Steam Input, the VR keyboard, find in page.
    static let browserViewNoOps = [
        "SetWindowStackingOrder", "AddGlass", "EnableSteamInput", "NotifyUserActivation",
        "SetTouchGesturesToCancel", "HandleContextMenuCommand", "SetSteamURLCallback",
        "SetShowContextMenuCallback", "SetBlockedProtocols", "Paste", "FindInPage", "StopFindInPage",
        "DialogResponse", "SetVRKeyboardVisibility", "AddHeader",
    ]

    /// The `SteamClient.BrowserView` methods the shim has.
    static let browserViewNamespace = [
        "Create", "CreatePopup", "Destroy", "PostMessageToParent", "RegisterForMessageFromParent",
    ]

    /// The events a native browser view fires at Steam's page.
    static let browserViewEvents = [
        "set-title", "history-changed", "can-go-back-forward-changed", "start-request", "start-loading",
        "finished-request", "load-error",
    ]

    /// Events Steam's code listens for with `.on(` that a browser view never
    /// fires here: find in page, tabs, security badges and favicons, and the
    /// events of other emitters (`message`, `openchange`, `virtualfocus`).
    static let browserViewEventsNotFired = [
        "before-close", "blocked-request", "ctrl-tab-pressed", "favicon-urls-changed", "find-in-page-results",
        "input-blocked", "message", "new-tab", "node-has-focus", "openchange", "page-security",
        "toggle-find-in-page", "virtualfocus",
    ]

    /// Why a field of an answer the app gives has no probe.
    static let unread = "Steam's scripts do not read it; the app sends it for the shape the client answers with"

    static let answeredSurfaces: [Entry] = [
        Entry(
            .answered, "SteamClient.Window", "every popup's window calls, answered for its NSWindow",
            .supplied(Supplied(
                shape: .namespace("SteamClient.Window"),
                answered: WindowCall.allCases.map(\.rawValue), ignored: WindowCall.unanswered,
            )),
            tokens: WindowCall.allCases.map(\.rawValue),
        ),
        Entry(
            .answered, "SteamClient.BrowserView", "the shim builds browser views itself",
            .supplied(Supplied(shape: .namespace("SteamClient.BrowserView"), answered: browserViewNamespace, ignored: [])),
            tokens: browserViewNamespace,
        ),
        Entry(
            .answered, "browser view methods", "the store, community and overlay pages in native child web views",
            .supplied(Supplied(
                shape: .receivers(["m_browser", "m_browserView"]),
                answered: browserViewMethods + browserViewNoOps, ignored: [],
            )),
            tokens: browserViewMethods + browserViewNoOps,
        ),
        Entry(
            .answered, "browser view events", "what a native child web view tells Steam's page",
            .supplied(Supplied(shape: .listeners, answered: browserViewEvents, ignored: browserViewEventsNotFired)),
            tokens: browserViewEvents,
        ),
        Entry(
            .answered, "Chromium-only APIs", "APIs WebKit lacks, supplied by the shim on every window",
            .chromium, tokens: ChromiumSurface.suppliedByShim.sorted(),
        ),
    ]

    static let windowNames: [Entry] = Popup.allCases.map { popup in
        Entry(.windowName, popup.rawValue, popup.use, .text([popup.needle]))
    } + [
        Entry(
            .windowName, popupInstanceMarker, "telling a popup's base name from its instance number",
            .text(["\"\(popupInstanceMarker)\""]),
        ),
        Entry(
            .windowName, rootMenuTitleSuffix, "finding the five root menus' popups for the Mac's menu bar",
            .text(["\(rootMenuTitleSuffix)`"]),
        ),
    ]

    static let messages: [Entry] = [
        Entry(.message, popupCreatedMessage, "telling a popup its window exists, so Steam renders into it", .text(["\"\(popupCreatedMessage)\""])),
        Entry(.message, windowResizedMessage, "telling a popup its window changed size", .text(["\"\(windowResizedMessage)\""])),
        Entry(.message, transportSocketPath, "tunneling the UI's protobuf socket through the client's own context", .text(["transportsocket"])),
        Entry(.message, loopbackHost, "the origin Steam's web properties allow, behind the same-origin proxy", .text([loopbackHost])),
        Entry(.message, "parentPopupBrowserID", "the window a new browser view belongs to", .identifier(passes: nil)),
        Entry(.message, "strInitialURL", "the page a browser view opens on, loaded by the host", .identifier(passes: nil)),
        Entry(.message, "strCreateURL", "what CreatePopup hands back with its view", .identifier(passes: nil)),
        Entry(.message, "bCanGoBack", "a browser view's history state, as Steam reads it", .identifier(passes: nil)),
        Entry(.message, "bCanGoForward", "a browser view's history state, in the shape the client answers with", .unchecked(unread)),
        Entry(.message, "minwidth", "a popup's size limits, in its about:blank query", .text(["minwidth"]), tokens: ["minwidth", "minheight"]),
        Entry(.message, "maxwidth", "a popup's size limits, in its about:blank query", .text(["maxwidth"]), tokens: ["maxwidth", "maxheight"]),
    ]
}
