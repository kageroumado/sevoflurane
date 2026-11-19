import Foundation
import notify
import Synchronization

/// macOS Game Mode, as the system announces it.
///
/// `gamepolicyd` posts `com.apple.gamepolicy.game-mode-session` with state 1
/// while a session is in force; the run recorder notes it.
nonisolated enum GameModeSignal {
    static let notification = "com.apple.gamepolicy.game-mode-session"

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

    /// Registered once: each `notify_register_check` token takes a slot in the
    /// process's shared page, which a token per call would exhaust.
    private static let checkToken = Mutex<Int32?>(nil)
}
