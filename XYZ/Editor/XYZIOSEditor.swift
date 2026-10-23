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

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 1 else { return }
        let side = XYZEditorStyle.sideInset(for: width)
        let next = UIEdgeInsets(
            top: XYZEditorStyle.markdown.verticalInset,
            left: side,
            bottom: XYZEditorStyle.markdown.verticalInset,
            right: side
        )
        if textContainerInset != next {
            textContainerInset = next
        }
    }

    func scrollAnchor() -> EditorScrollAnchor {
        let span = max(contentSize.height - bounds.height, 1)
        let fraction = min(1, max(0, contentOffset.y / span))
        let point = CGPoint(x: textContainerInset.left + 8, y: contentOffset.y + textContainerInset.top + 4)
        guard let position = closestPosition(to: point), let text else {
            return EditorScrollAnchor(fraction: fraction, probe: "")
        }
        let ns = text as NSString
        guard ns.length > 0 else {
            return EditorScrollAnchor(fraction: fraction, probe: "")
        }
        let index = min(max(0, offset(from: beginningOfDocument, to: position)), ns.length - 1)
        var range = ns.lineRange(for: NSRange(location: index, length: 0))
        if range.length > 0 {
            let last = ns.character(at: NSMaxRange(range) - 1)
            if last == 0x0A || last == 0x0D {
                range.length -= 1
            }
        }
        return EditorScrollAnchor(fraction: fraction, probe: EditorScrollAnchor.probe(from: ns.substring(with: range)))
    }

    func reveal(_ anchor: EditorScrollAnchor) {
        let location = anchor.utf16Location(in: text ?? "")
        let start = position(from: beginningOfDocument, offset: location) ?? beginningOfDocument
        scrollRangeToVisible(NSRange(location: location, length: 0))
        let rect = caretRect(for: start)
        scrollRectToVisible(CGRect(x: 0, y: max(0, rect.minY - textContainerInset.top), width: 1, height: bounds.height))
    }
}

struct XYZIOSEditor: UIViewRepresentable {
    var text: String
    var isEditable: Bool
    var undoManager: UndoManager?
    var reloadToken: Int
    var monospaced: Bool
    var scrollLink: EditorScrollLink
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
        applyTypingStyle(to: textView, monospaced: monospaced, restyleStorage: false)
        textView.text = text
        applyTypingStyle(to: textView, monospaced: monospaced, restyleStorage: true)

        context.coordinator.textView = textView
        context.coordinator.onTextChange = onTextChange
        context.coordinator.monospaced = monospaced
        textView.delegate = context.coordinator
        textView.documentUndoManager = undoManager
        assert(textView.textLayoutManager != nil, "XYZEditor requires TextKit 2")
        return textView
    }

    func updateUIView(_ textView: XYZIOSTextView, context: Context) {
        context.coordinator.onTextChange = onTextChange
        context.coordinator.scrollLink = scrollLink
        textView.isEditable = isEditable
        textView.documentUndoManager = undoManager
        scrollLink.capture = { [weak textView] in
            textView?.scrollAnchor() ?? EditorScrollAnchor(fraction: 0, probe: "")
        }
        if let anchor = scrollLink.take(for: .source) {
            DispatchQueue.main.async { [weak textView] in
                textView?.reveal(anchor)
            }
        }
        let styleChanged = context.coordinator.monospaced != monospaced
        if styleChanged {
            context.coordinator.monospaced = monospaced
        }
        var replaced = false
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            if (textView.text ?? "") != text {
                context.coordinator.perform(.replaceContents(text))
                replaced = true
            }
        }
        applyTypingStyle(to: textView, monospaced: monospaced, restyleStorage: styleChanged || replaced)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func applyTypingStyle(to textView: UITextView, monospaced: Bool, restyleStorage: Bool) {
        let style = XYZEditorStyle(monospaced: monospaced)
        let base = Self.face(style)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        let paragraph = style.paragraphStyle(naturalLineHeight: font.lineHeight)
        textView.font = font
        let width = textView.bounds.width
        let side = width > 1 ? XYZEditorStyle.sideInset(for: width) : style.horizontalInset
        textView.textContainerInset = UIEdgeInsets(
            top: style.verticalInset,
            left: side,
            bottom: style.verticalInset,
            right: side
        )
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]
        let storage = textView.textStorage
        guard restyleStorage, storage.length > 0 else { return }
        let range = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.font, value: font, range: range)
        storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        storage.endEditing()
    }

    /// System font for Latin, PingFang SC for Chinese.
    private static func face(_ style: XYZEditorStyle) -> UIFont {
        if style.monospaced {
            return UIFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
        }
        let base = UIFont.systemFont(ofSize: style.fontSize, weight: .regular)
        let fallback = UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [fallback],
        ])
        return UIFont(descriptor: descriptor, size: style.fontSize)
    }

    final class Coordinator: NSObject, UITextViewDelegate, XYZTextEditing {
        var textView: XYZIOSTextView?
        var onTextChange: (String) -> Void = { _ in }
        var scrollLink: EditorScrollLink?
        var reloadToken = 0
        var monospaced = false
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
