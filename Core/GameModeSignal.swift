import Foundation
import notify
import Synchronization

/// macOS Game Mode, as the system announces it.
///
/// `gamepolicyd` posts `com.apple.gamepolicy.game-mode-session` whenever a
/// Game Mode session begins or ends, with the notification's state at 1
/// while one is in force. A game whose launcher bundle carries
/// `LSApplicationCategoryType = games` gets a session when its window goes
/// full screen; a bare `wine` process never does. Whether the mode was on
/// during a run is a fact about how the run performed, so the recorder
/// asks here and notes it in the record.
nonisolated enum GameModeSignal {
    static let notification = "com.apple.gamepolicy.game-mode-session"

    /// Whether a Game Mode session is in force right now.
    static func isActive() -> Bool {
        var state: UInt64 = 0
        let token = checkToken.withLock { token -> Int32 in
            if token == nil {
                var registered: Int32 = 0
                if notify_register_check(notification, &registered) == NOTIFY_STATUS_OK {
                    token = registered
                }
            }
            return token ?? -1
        }
        guard token >= 0, notify_get_state(token, &state) == NOTIFY_STATUS_OK else { return false }
        return state != 0
    }

    /// The registration is made once and kept: `notify_register_check` hands
    /// out a token backed by a slot in the process's shared page, and a token
    /// per call would spend them until the process ran out.
    private static let checkToken = Mutex<Int32?>(nil)
}
