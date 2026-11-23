import AppKit
import SwiftUI

/// The button that saves the zip, with its own progress and its own error.
struct SaveDiagnosticsButton: View {
    @Binding var error: String?
    @State private var isSaving = false

    var body: some View {
        Button(isSaving ? "Saving…" : "Save Diagnostics") {
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
