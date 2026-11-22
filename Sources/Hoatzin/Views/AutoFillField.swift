import AppKit
import SwiftUI

/// Holds a weak reference to the underlying NSTextField so values inserted by
/// Password AutoFill can be read even if no change notification was delivered.
final class FieldHandle {
    weak var field: NSTextField?
    var value: String? { field?.stringValue }
}

/// NSTextField / NSSecureTextField with a `contentType`, which is what makes macOS offer
/// Password AutoFill (credentials from the Passwords app, unlocked with Touch ID).
struct AutoFillField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var secure: Bool = false
    var contentType: NSTextContentType? = nil
    var isEnabled: Bool = true
    var autofocus: Bool = false
    var handle: FieldHandle? = nil
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder
        field.contentType = contentType
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.stringValue = text
        handle?.field = field
        if autofocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil { field.stringValue = text }
        field.isEnabled = isEnabled
        handle?.field = field
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutoFillField

        init(_ parent: AutoFillField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSTextField) {
            parent.text = sender.stringValue
            // Only submit on Return, not when focus merely moves away.
            if NSApp.currentEvent?.type == .keyDown { parent.onSubmit() }
        }
    }
}
