import AppKit
import SwiftUI

/// A combo box that completes as you type from a list of known names, and
/// accepts any other.
struct SettingsComboField: NSViewRepresentable {
    @Binding var text: String
    let completions: [String]
    let prompt: String

    private enum Metrics {
        static let visibleItems = 12
    }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = true
        box.usesDataSource = false
        box.numberOfVisibleItems = Metrics.visibleItems
        box.placeholderString = prompt
        box.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        box.delegate = context.coordinator
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.text = $text
        if box.objectValues as? [String] != completions {
            box.removeAllItems()
            box.addItems(withObjectValues: completions)
        }
        if box.stringValue != text { box.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            text.wrappedValue = box.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let picked = box.itemObjectValue(at: box.indexOfSelectedItem) as? String else { return }
            text.wrappedValue = picked
        }
    }
}
