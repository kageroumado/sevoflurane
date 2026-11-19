import Propofol
import SwiftUI

/// Exactly what one shared run sends, as JSON, behind a disclosure.
struct SharedRunPreview: View {
    var run = SharedRun.example(appVersion: StatsUploader.appVersion)

    var body: some View {
        DisclosureGroup("Show exactly what is sent") {
            ScrollView {
                Text(verbatim: run.json)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(.top, Theme.Space.xs)
        }
    }
}
