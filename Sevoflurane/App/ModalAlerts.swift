import Foundation

/// Where a modal alert the app raises by itself runs: a turn of the main run
/// loop of its own.
///
/// Never from a `DispatchQueue.main` block or a main-actor task: the main
/// queue runs one block at a time, so a modal loop inside one holds back
/// every other main-queue block and main-actor job until the alert closes.
/// The control endpoint and the helper's link are among them, and while a
/// question waits for its answer `sevo status` read the app and the helper as
/// not running. A run-loop turn is outside the queue, and the modal loop
/// drains it as usual.
@MainActor
enum ModalAlerts {
    static func present(_ alert: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated(alert)
        }
    }
}
