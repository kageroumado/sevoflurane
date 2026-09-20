import AppKit
import SwiftUI

/// The libraries the active engine ships, which are the names an override
/// can change the load order of — the list winecfg's Libraries tab offers.
enum BuiltinLibraries {
    /// Names without `.dll`, sorted, read from the engine's 64-bit modules.
    static func names(engine: Engine = .active) -> [String] {
        // A managed engine keeps Wine under `wine/`; CrossOver's tree is Wine's own.
        let files = ["wine/lib/wine/x86_64-windows", "lib/wine/x86_64-windows"]
            .lazy
            .compactMap { try? FileManager.default.contentsOfDirectory(atPath: engine.root.appendingPathComponent($0).path) }
            .first ?? []
        return files
            .filter { $0.hasSuffix(".dll") }
            .map { String($0.dropLast(".dll".count)) }
            .sorted()
    }

    /// A typed name as the registry spells it: lower case, no extension.
    static func normalized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasSuffix(".dll") ? String(trimmed.dropLast(".dll".count)) : trimmed
    }
}

/// A combo box over the engine's libraries: type a name and it completes, or
/// open the list and pick one. Any other name is accepted as typed, since a
/// game can bring a library Wine has no copy of.
struct DLLNameField: NSViewRepresentable {
    @Binding var name: String
    let names: [String]
    var placeholder = "Library, like dinput8"

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = true
        box.usesDataSource = false
        box.numberOfVisibleItems = 12
        box.placeholderString = placeholder
        box.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        box.delegate = context.coordinator
        box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.name = $name
        if box.numberOfItems != names.count {
            box.removeAllItems()
            box.addItems(withObjectValues: names)
        }
        if box.stringValue != name { box.stringValue = name }
    }

    func makeCoordinator() -> Coordinator { Coordinator(name: $name) }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var name: Binding<String>

        init(name: Binding<String>) { self.name = name }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            name.wrappedValue = box.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let picked = box.itemObjectValue(at: box.indexOfSelectedItem) as? String else { return }
            name.wrappedValue = picked
        }
    }
}
