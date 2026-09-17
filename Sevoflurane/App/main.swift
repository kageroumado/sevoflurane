import AppKit

// macOS 27 can mirror an app's menus into its menu-bar agent, and a title's
// dropdown then tracks in a session whose dismissal can stall on a completion
// the parked run loop never delivers, freezing the main thread. This is Apple's
// own compatibility switch for menus that must stay in this process; AppKit
// reads it from the defaults domain, once, the first time a menu asks, so it is
// written before NSApplication exists. Earlier releases ignore it.
UserDefaults.standard.set(true, forKey: "NSMenuDisableOutOfProcessMenusDueToIncompatibility")

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
