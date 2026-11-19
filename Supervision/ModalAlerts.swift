import Foundation

/// Runs a modal alert on a main run-loop turn of its own.
///
/// Never from a `DispatchQueue.main` block or a main-actor task: a modal loop
/// there holds back every main-queue job, the control endpoint and helper
/// link included, until it closes.
@MainActor
enum ModalAlerts {
    static func present(_ alert: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated(alert)
        }
    }
}
