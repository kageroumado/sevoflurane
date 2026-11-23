import Propofol
import SwiftUI

/// Exactly what one shared run sends, as JSON, behind a disclosure.
struct SharedRunPreview: View {
    /// Built once: the sample reads this Mac's hardware.
    static let json = SharedRun.example(appVersion: StatsUploader.appVersion).json

    var body: some View {
        DisclosureGroup("Show exactly what is sent") {
            ScrollView {
                Text(verbatim: Self.json)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(.top, Theme.Space.xs)
        }
    }
}
