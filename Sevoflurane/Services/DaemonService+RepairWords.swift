import Foundation

extension DaemonService.RepairResult {
    /// What a repair came to, as every surface that offers one says it.
    var sentence: String {
        switch self {
        case .reachable: String(localized: "The background helper is running.")
        case .alreadyHealthy: String(localized: "The background helper is already healthy.")
        case .restartedClient: String(localized: "The background helper had given up on Steam. Steam is restarting.")
        case let .needsApproval(message), let .failed(message): InterfaceCopy.localized(message)
        }
    }

    /// Whether the helper is still down after the repair.
    var isFailure: Bool {
        switch self {
        case .reachable, .alreadyHealthy, .restartedClient: false
        case .needsApproval, .failed: true
        }
    }
}
