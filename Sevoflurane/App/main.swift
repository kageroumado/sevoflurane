import AppKit

// The app runs on the AppKit lifecycle rather than SwiftUI's `App`.
//
// A SwiftUI `App` owns the menu bar: on every transaction of its scene graph
// it rebuilds `NSApp.mainMenu` from its own model and discards every item it
// did not create. This app's menu bar is Steam's own strip, mirrored into
// native menus by `SteamMenuMirror`, so the two cannot both hold the pen.
// SwiftUI is still what draws the popover and Settings — hosted in AppKit
// windows, where its graph reaches nothing but its own views.
//
// `NSApp` is nil until `NSApplication.shared` creates it, so the order below
// is load-bearing: share, then delegate, then run. `NSApplicationMain` is not
// used because there is no nib or storyboard for it to load.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
