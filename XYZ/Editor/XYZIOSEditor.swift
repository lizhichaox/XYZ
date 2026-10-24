#if os(iOS)
import SwiftUI
import UIKit
import XYZCore

/// TextKit 2 plain-text view. Subclass is the place for future shortcuts and find/replace.
final class XYZIOSTextView: UITextView {
    weak var documentUndoManager: UndoManager?
    var allowsMarkup = true
    var isApplyingMarkupEdit = false
    /// Restored once, after the view is in a window and the inset matches the pane.
    private var pendingAnchor: EditorScrollAnchor?
    private var isAligning = false

    override var undoManager: UndoManager? {
        documentUndoManager ?? super.undoManager
    }

    /// Let the text view fill the editor and scroll, instead of growing with the document.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isAligning else { return }
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
        alignIfReady()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        alignIfReady()
    }

    func scrollAnchor() -> EditorScrollAnchor {
        let span = max(contentSize.height - bounds.height, 1)
        let fraction = min(1, max(0, contentOffset.y / span))
        let line = viewportTopLine()
        ViewAnchorLog.captured(from: "source", line: line)
        let value = text ?? ""
        let ns = value as NSString
        guard ns.length > 0 else {
            return EditorScrollAnchor(fraction: fraction, probe: "", line: line)
        }
        let location = min(max(0, EditorScrollAnchor.utf16Location(ofLine: line, in: value)), ns.length - 1)
        var range = ns.lineRange(for: NSRange(location: location, length: 0))
        if range.length > 0 {
            let last = ns.character(at: NSMaxRange(range) - 1)
            if last == 0x0A || last == 0x0D {
                range.length -= 1
            }
        }
        return EditorScrollAnchor(
            fraction: fraction,
            probe: EditorScrollAnchor.probe(from: ns.substring(with: range)),
            line: line
        )
    }

    override var keyCommands: [UIKeyCommand]? {
        let existing = super.keyCommands ?? []
        guard allowsMarkup else { return existing }
        let bold = UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(xyzToggleBold(_:)))
        let italic = UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(xyzToggleItalic(_:)))
        let outdent = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(xyzOutdent(_:)))
        bold.wantsPriorityOverSystemBehavior = true
        italic.wantsPriorityOverSystemBehavior = true
        return existing + [bold, italic, outdent]
    }

    override func insertText(_ text: String) {
        if text == "\t", applyMarkupEdit(SourceEditing.indent(in: self.text ?? "", selection: sourceSelection())) {
            return
        }
        super.insertText(text)
    }

    @objc func xyzToggleBold(_ sender: Any?) {
        _ = applyMarkupEdit(SourceEditing.toggleBold(in: text ?? "", selection: sourceSelection()))
    }

    @objc func xyzToggleItalic(_ sender: Any?) {
        _ = applyMarkupEdit(SourceEditing.toggleItalic(in: text ?? "", selection: sourceSelection()))
    }

    @objc func xyzOutdent(_ sender: Any?) {
        _ = applyMarkupEdit(SourceEditing.outdent(in: text ?? "", selection: sourceSelection()))
    }

    func sourceSelection() -> SourceRange {
        let range = selectedRange
        return SourceRange(location: range.location, length: range.length)
    }

    @discardableResult
    func applyMarkupEdit(_ edit: SourceReplacement?) -> Bool {
        guard isEditable, allowsMarkup, markedTextRange == nil, !isApplyingMarkupEdit, let edit else { return false }
        let start = position(from: beginningOfDocument, offset: edit.range.location) ?? beginningOfDocument
        let end = position(from: start, offset: edit.range.length) ?? start
        guard let range = textRange(from: start, to: end) else { return false }
        isApplyingMarkupEdit = true
        defer { isApplyingMarkupEdit = false }
        replace(range, withText: edit.text)
        let caret = position(from: beginningOfDocument, offset: edit.selection.location) ?? endOfDocument
        let caretEnd = position(from: caret, offset: edit.selection.length) ?? caret
        if let selected = textRange(from: caret, to: caretEnd) {
            selectedTextRange = selected
        }
        return true
    }

    /// Remember the line and align on the next layout that has a window and a real inset. One scroll.
    func reveal(_ anchor: EditorScrollAnchor) {
        pendingAnchor = anchor
        alignIfReady()
        setNeedsLayout()
    }

    private func alignIfReady() {
        guard let anchor = pendingAnchor, !isAligning, window != nil, bounds.width > 1 else { return }
        let side = XYZEditorStyle.sideInset(for: bounds.width)
        let top = XYZEditorStyle.markdown.verticalInset
        let inset = textContainerInset
        guard abs(inset.top - top) < 0.5, abs(inset.left - side) < 0.5, abs(inset.right - side) < 0.5 else { return }
        pendingAnchor = nil
        UIView.performWithoutAnimation {
            scrollLineToTop(anchor)
        }
    }

    /// Lay out from the start of the document through the target line, then put that line
    /// where the first line sits. `animated` stays false so a SwiftUI view-mode animation cannot glide the offset.
    private func scrollLineToTop(_ anchor: EditorScrollAnchor) {
        isAligning = true
        defer { isAligning = false }
        let value = text ?? ""
        let length = (value as NSString).length
        let location = min(max(0, anchor.utf16Location(in: value)), length)
        let requested = anchor.line > 0 ? anchor.line : EditorScrollAnchor.lineNumber(at: location, in: value)
        var y = lineOffset(utf16: location) ?? 0
        if contentSize.height < y + bounds.height, let manager = textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
            layoutIfNeeded()
            y = lineOffset(utf16: location) ?? y
        }
        let maxY = max(0, contentSize.height - bounds.height)
        let target = min(max(0, y), max(maxY, 0))
        setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: false)
        ViewAnchorLog.aligned(to: "source", requested: requested, landed: viewportTopLine())
    }

    private func lineOffset(utf16: Int) -> CGFloat? {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return nil }
        let document = content.documentRange
        let value = text ?? ""
        let length = (value as NSString).length
        let clamped = min(max(0, utf16), length)
        let start = content.location(document.location, offsetBy: clamped) ?? document.location
        let end = content.location(start, offsetBy: 1) ?? document.endLocation
        // Failable on the 27.1 SDK, non-optional on 26.6. The annotation accepts both.
        let layoutRange: NSTextRange? = NSTextRange(location: document.location, end: end)
        if let layoutRange {
            manager.ensureLayout(for: layoutRange)
        } else {
            manager.ensureLayout(for: manager.documentRange)
        }
        let fragment = manager.textLayoutFragment(for: start)
            ?? (clamped > 0 ? content.location(document.location, offsetBy: clamped - 1).flatMap { manager.textLayoutFragment(for: $0) } : nil)
        guard let fragment else { return 0 }
        let lineTop = textContainerInset.top + fragment.layoutFragmentFrame.minY
        return lineTop - textContainerInset.top
    }

    /// The source line whose top is at the viewport's content top.
    /// Uses the same fragment frame as `lineOffset`, so capture and restore name one line.
    private func viewportTopLine() -> Int {
        let value = text ?? ""
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return 1 }
        let marker = contentOffset.y + 0.5
        var found: NSTextLayoutFragment?
        manager.enumerateTextLayoutFragments(
            from: content.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let bottom = textContainerInset.top + fragment.layoutFragmentFrame.maxY - textContainerInset.top
            if bottom > marker {
                found = fragment
                return false
            }
            return true
        }
        guard let found else { return 1 }
        let offset = content.offset(from: content.documentRange.location, to: found.rangeInElement.location)
        return EditorScrollAnchor.lineNumber(at: max(0, offset), in: value)
    }
}

struct XYZIOSEditor: UIViewRepresentable {
    var text: String
    var isEditable: Bool
    var undoManager: UndoManager?
    var reloadToken: Int
    var monospaced: Bool
    var scrollLink: EditorScrollLink
    var markup: Bool
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

        textView.allowsMarkup = markup
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
        textView.allowsMarkup = markup
        textView.documentUndoManager = undoManager
        scrollLink.capture = { [weak textView] in
            textView?.scrollAnchor() ?? EditorScrollAnchor(fraction: 0, probe: "", line: 1)
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
        if let anchor = scrollLink.take(for: .source) {
            textView.reveal(anchor)
        }
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

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !isApplyingExternalText else { return true }
            guard let view = textView as? XYZIOSTextView else { return true }
            guard text == "\n", range.length == 0, view.markedTextRange == nil else { return true }
            let selection = SourceRange(location: range.location, length: range.length)
            guard let edit = SourceEditing.newline(in: view.text ?? "", selection: selection) else { return true }
            DispatchQueue.main.async { [weak view] in
                _ = view?.applyMarkupEdit(edit)
            }
            return false
        }
    }
}
#endif
