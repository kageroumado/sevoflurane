import Foundation

/// Exactly what one shared run sends, as JSON: what every surface that asks
/// about sharing shows behind its disclosure.
enum SharedRunPreview {
    /// Built once: the sample reads this Mac's hardware.
    static let json = SharedRun.example(appVersion: StatsUploader.appVersion).json
}
