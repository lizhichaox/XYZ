#if os(macOS)
import AppKit
import SwiftUI

/// TextKit 2 plain-text view. Subclass is the place for future shortcuts and find/replace.
final class XYZMacTextView: NSTextView {
    weak var documentUndoManager: UndoManager?

    override var undoManager: UndoManager? {
        documentUndoManager ?? super.undoManager
    }
}

struct XYZMacEditor: NSViewRepresentable {
    var text: String
    var isEditable: Bool
    var undoManager: UndoManager?
    var reloadToken: Int
    var onTextChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = XYZMacTextView(usingTextLayoutManager: true)
        let style = XYZEditorStyle.markdown
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        let font = NSFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
        textView.font = font

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]

        textView.textContainerInset = NSSize(width: style.horizontalInset, height: style.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("Markdown editor")
        textView.string = text

        context.coordinator.textView = textView
        context.coordinator.onTextChange = onTextChange
        textView.delegate = context.coordinator
        textView.documentUndoManager = undoManager

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        assert(textView.textLayoutManager != nil, "XYZEditor requires TextKit 2")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? XYZMacTextView else { return }
        context.coordinator.onTextChange = onTextChange
        textView.isEditable = isEditable
        textView.documentUndoManager = undoManager
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            if textView.string != text {
                context.coordinator.perform(.replaceContents(text))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSTextViewDelegate, XYZTextEditing {
        var textView: XYZMacTextView?
        var onTextChange: (String) -> Void = { _ in }
        var reloadToken = 0
        private var isApplyingExternalText = false

        var text: String {
            textView?.string ?? ""
        }

        var textLayoutManager: NSTextLayoutManager? {
            textView?.textLayoutManager
        }

        func perform(_ command: XYZEditorCommand) {
            guard let textView else { return }
            switch command {
            case .replaceContents(let replacement):
                isApplyingExternalText = true
                textView.string = replacement
                isApplyingExternalText = false
                onTextChange(replacement)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText else { return }
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange(textView.string)
        }
    }
}
#endif
