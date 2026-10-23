#if os(iOS)
import SwiftUI
import UIKit

/// TextKit 2 plain-text view. Subclass is the place for future shortcuts and find/replace.
final class XYZIOSTextView: UITextView {
    weak var documentUndoManager: UndoManager?

    override var undoManager: UndoManager? {
        documentUndoManager ?? super.undoManager
    }

    /// Let the text view fill the editor and scroll, instead of growing with the document.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

struct XYZIOSEditor: UIViewRepresentable {
    var text: String
    var isEditable: Bool
    var undoManager: UndoManager?
    var reloadToken: Int
    var onTextChange: (String) -> Void

    func makeUIView(context: Context) -> XYZIOSTextView {
        let textView = XYZIOSTextView(usingTextLayoutManager: true)
        let style = XYZEditorStyle.markdown
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.tintColor = .label
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsEditingTextAttributes = false
        textView.autocorrectionType = .default
        textView.spellCheckingType = .yes
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = []
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(
            top: style.verticalInset,
            left: style.horizontalInset,
            bottom: style.verticalInset,
            right: style.horizontalInset
        )
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.accessibilityLabel = "Markdown editor"
        applyTypingStyle(to: textView)
        textView.text = text

        context.coordinator.textView = textView
        context.coordinator.onTextChange = onTextChange
        textView.delegate = context.coordinator
        textView.documentUndoManager = undoManager
        assert(textView.textLayoutManager != nil, "XYZEditor requires TextKit 2")
        return textView
    }

    func updateUIView(_ textView: XYZIOSTextView, context: Context) {
        context.coordinator.onTextChange = onTextChange
        textView.isEditable = isEditable
        textView.documentUndoManager = undoManager
        applyTypingStyle(to: textView)
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            if (textView.text ?? "") != text {
                context.coordinator.perform(.replaceContents(text))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func applyTypingStyle(to textView: UITextView) {
        let style = XYZEditorStyle.markdown
        let base = UIFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        textView.font = font
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
    }

    final class Coordinator: NSObject, UITextViewDelegate, XYZTextEditing {
        var textView: XYZIOSTextView?
        var onTextChange: (String) -> Void = { _ in }
        var reloadToken = 0
        private var isApplyingExternalText = false

        var text: String {
            textView?.text ?? ""
        }

        var textLayoutManager: NSTextLayoutManager? {
            textView?.textLayoutManager
        }

        func perform(_ command: XYZEditorCommand) {
            guard let textView else { return }
            switch command {
            case .replaceContents(let replacement):
                isApplyingExternalText = true
                textView.text = replacement
                isApplyingExternalText = false
                onTextChange(replacement)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalText else { return }
            onTextChange(textView.text ?? "")
        }
    }
}
#endif
