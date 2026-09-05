import AppKit
import SwiftUI

/// The smallest AppKit boundary required by the composer.
///
/// SwiftUI remains the source of truth for text. `NSTextView` contributes its text
/// input client so marked text from Chinese and other IMEs is committed normally,
/// while a bare Return can be distinguished from Shift-Return.
@MainActor
struct AppKitComposerEditor: NSViewRepresentable {
    static let horizontalTextInset: CGFloat = 8

    @Binding var text: String
    let isEditable: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = SubmittingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = context.coordinator.submit
        textView.string = text
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: Self.horizontalTextInset, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("Message")

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = scrollView.documentView as? SubmittingTextView else { return }
        textView.onSubmit = context.coordinator.submit
        textView.isEditable = isEditable

        // Never replace the backing string while an input method owns marked text.
        // Doing so discards the candidate session and is the common source of broken
        // Chinese input in hand-rolled SwiftUI/AppKit editors.
        guard !textView.hasMarkedText(), textView.string != text else { return }

        let selectedRange = textView.selectedRange()
        textView.string = text
        let length = (text as NSString).length
        if selectedRange.location != NSNotFound, NSMaxRange(selectedRange) <= length {
            textView.setSelectedRange(selectedRange)
        } else {
            textView.setSelectedRange(NSRange(location: length, length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AppKitComposerEditor

        init(parent: AppKitComposerEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                parent.isEditable,
                parent.text != textView.string
            else { return }
            parent.text = textView.string
        }

        func submit() {
            parent.onSubmit()
        }
    }
}

@MainActor
private final class SubmittingTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else {
            super.keyDown(with: event)
            return
        }

        // Return must first commit an active IME candidate. The following Return,
        // once no marked range remains, is the send command.
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }

        let shortcutModifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])

        if shortcutModifiers == [.shift] {
            insertNewline(self)
        } else if shortcutModifiers.isEmpty {
            onSubmit?()
        } else {
            super.keyDown(with: event)
        }
    }
}
