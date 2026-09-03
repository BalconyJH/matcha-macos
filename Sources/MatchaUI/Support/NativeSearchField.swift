import AppKit
import SwiftUI

/// A scoped macOS search field for panes that cannot use SwiftUI's toolbar-level
/// `searchable` placement without moving the control out of its owning pane.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.controlSize = .regular
        searchField.bezelStyle = .roundedBezel
        searchField.placeholderString = prompt
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = context.coordinator
        searchField.setAccessibilityLabel(accessibilityLabel)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.text = $text
        searchField.placeholderString = prompt
        searchField.setAccessibilityLabel(accessibilityLabel)
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }
    }
}
