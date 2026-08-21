import AppKit
import SwiftUI

/// Status-bar page box: type a page number, press Return to jump there.
///
/// Backed by AppKit because `@FocusState` is macOS 12+, and because the field must
/// ignore incoming page updates while the user is mid-edit.
struct PageNumberField: NSViewRepresentable {
    /// Current page, 1-based.
    let page: Int
    let pageCount: Int
    /// Called with the requested 1-based page when the user commits.
    let onCommit: (Int) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "\(page)")
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.toolTip = "Type a page number and press Return"
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.pageCount = pageCount
        // Never overwrite what the user is typing.
        guard !context.coordinator.isEditing else { return }
        let text = "\(page)"
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, pageCount: pageCount)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (Int) -> Void
        var pageCount: Int
        private(set) var isEditing = false

        init(onCommit: @escaping (Int) -> Void, pageCount: Int) {
            self.onCommit = onCommit
            self.pageCount = pageCount
        }

        func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }
        func controlTextDidEndEditing(_ obj: Notification) { isEditing = false }

        @objc func commit(_ sender: NSTextField) {
            isEditing = false
            let trimmed = sender.stringValue.trimmingCharacters(in: .whitespaces)
            guard let requested = Int(trimmed), pageCount > 0 else { return }
            onCommit(min(max(requested, 1), pageCount))
            sender.window?.makeFirstResponder(nil)
        }
    }
}
