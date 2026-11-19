import AppKit
import SwiftUI

/// The button that saves the zip, with its own progress and its own error.
struct SaveDiagnosticsButton: View {
    let title: LocalizedStringKey
    @Binding var error: String?
    @State private var isSaving = false

    var body: some View {
        Button(isSaving ? "Saving…" : title) {
            isSaving = true
            error = nil
            Task(name: "Save diagnostics") {
                error = await DiagnosticsArchive.save()
                isSaving = false
            }
        }
        .disabled(isSaving)
    }
}
