#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

/// TextKit 2 editor. Attributes are display-only: the saved value is still `string`.
final class XYZMacTextView: NSTextView {
    weak var documentUndoManager: UndoManager?
    var onAppearanceChange: (() -> Void)?
    var allowsMarkup = true

    override var undoManager: UndoManager? {
        documentUndoManager ?? super.undoManager
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func changeFont(_ sender: Any?) {}

    override func changeColor(_ sender: Any?) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditorCommands.shared.handleKeyEquivalent(event) {
            return true
        }
        if markupKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘B and ⌘I. AppKit has no `toggleBoldface` on NSResponder; the text view handles the keys itself.
    private func markupKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b":
            return applyMarkupEdit(SourceEditing.toggleBold(in: string, selection: sourceSelection()))
        case "i":
            return applyMarkupEdit(SourceEditing.toggleItalic(in: string, selection: sourceSelection()))
        default:
            return false
        }
    }

    override func insertNewline(_ sender: Any?) {
        guard applyMarkupEdit(SourceEditing.newline(in: string, selection: sourceSelection())) else {
            super.insertNewline(sender)
            return
        }
    }

    override func insertTab(_ sender: Any?) {
        guard applyMarkupEdit(SourceEditing.indent(in: string, selection: sourceSelection())) else {
            super.insertTab(sender)
            return
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard applyMarkupEdit(SourceEditing.outdent(in: string, selection: sourceSelection())) else {
            super.insertBacktab(sender)
            return
        }
    }

    private func sourceSelection() -> SourceRange {
        let range = selectedRange()
        return SourceRange(location: range.location, length: range.length)
    }

    @discardableResult
    private func applyMarkupEdit(_ edit: SourceReplacement?) -> Bool {
        guard isEditable, allowsMarkup, !hasMarkedText(), let edit, let storage = textStorage else { return false }
        let range = NSRange(location: edit.range.location, length: edit.range.length)
        guard shouldChangeText(in: range, replacementString: edit.text) else { return false }
        storage.replaceCharacters(in: range, with: edit.text)
        didChangeText()
        let length = (string as NSString).length
        let location = min(max(0, edit.selection.location), length)
        let selectionLength = min(max(0, edit.selection.length), length - location)
        setSelectedRange(NSRange(location: location, length: selectionLength))
        return true
    }

    override func layout() {
        super.layout()
        guard let width = enclosingScrollView?.contentSize.width, width > 1 else { return }
        let side = XYZEditorStyle.sideInset(for: width)
        let next = NSSize(width: side, height: XYZEditorStyle.markdown.verticalInset)
        if textContainerInset != next {
            textContainerInset = next
        }
    }

    func scrollAnchor() -> EditorScrollAnchor {
        guard let scroll = enclosingScrollView else {
            return EditorScrollAnchor(fraction: 0, probe: "")
        }
        let visible = scroll.contentView.bounds
        let span = max(bounds.height - visible.height, 1)
        let fraction = min(1, max(0, visible.origin.y / span))
        let point = convert(NSPoint(x: visible.midX, y: visible.minY + 4), from: scroll.contentView)
        let index = characterIndexForInsertion(at: point)
        let ns = string as NSString
        guard index != NSNotFound, index >= 0, ns.length > 0 else {
            return EditorScrollAnchor(fraction: fraction, probe: "")
        }
        let safe = min(index, ns.length - 1)
        let range = ns.lineRange(for: NSRange(location: safe, length: 0))
        var content = range
        if content.length > 0 {
            let last = ns.character(at: NSMaxRange(content) - 1)
            if last == 0x0A || last == 0x0D {
                content.length -= 1
            }
        }
        let probe = EditorScrollAnchor.probe(from: ns.substring(with: content))
        return EditorScrollAnchor(fraction: fraction, probe: probe)
    }

    func reveal(_ anchor: EditorScrollAnchor) {
        let length = (string as NSString).length
        let location = min(max(0, anchor.utf16Location(in: string)), length)
        scrollRangeToVisible(NSRange(location: location, length: 0))
    }
}

struct XYZMacEditor: NSViewRepresentable {
    var text: String
    var isEditable: Bool
    var undoManager: UndoManager?
    var reloadToken: Int
    var monospaced: Bool
    var scrollLink: EditorScrollLink
    var markup: Bool
    var onTextChange: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = XYZMacTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
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
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("Markdown editor")

        context.coordinator.textView = textView
        context.coordinator.onTextChange = onTextChange
        context.coordinator.monospaced = monospaced
        textView.allowsMarkup = markup
        textView.delegate = context.coordinator
        textView.documentUndoManager = undoManager
        textView.onAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.restyle(edited: nil)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.scrollerInsets = NSEdgeInsets()
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = NSEdgeInsets()
        scrollView.contentView.drawsBackground = true
        scrollView.documentView = textView
        applyChrome(textView: textView, scrollView: scrollView, monospaced: monospaced)
        textView.string = text
        context.coordinator.restyle(edited: nil)
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
        context.coordinator.scrollLink = scrollLink
        textView.isEditable = isEditable
        textView.allowsMarkup = markup
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
            applyChrome(textView: textView, scrollView: scrollView, monospaced: monospaced)
        }
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            if textView.string != text {
                context.coordinator.perform(.replaceContents(text))
            } else if styleChanged {
                context.coordinator.restyle(edited: nil)
            }
        } else if styleChanged {
            context.coordinator.restyle(edited: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 480)
    }

    private func applyChrome(textView: XYZMacTextView, scrollView: NSScrollView, monospaced: Bool) {
        let style = XYZEditorStyle(monospaced: monospaced)
        let font = EditorTypography.baseFont(style)
        let paragraph = style.paragraphStyle(naturalLineHeight: EditorTypography.naturalLineHeight(font))
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        textView.textContainerInset = NSSize(width: style.horizontalInset, height: style.verticalInset)
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = .textBackgroundColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate, XYZTextEditing {
        var textView: XYZMacTextView?
        var onTextChange: (String) -> Void = { _ in }
        var scrollLink: EditorScrollLink?
        var reloadToken = 0
        var monospaced = false
        private var isApplyingExternalText = false
        private var isRestyling = false
        private var editedRange: NSRange?
        private var laterRestyle: DispatchWorkItem?

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
                laterRestyle?.cancel()
                restyle(edited: nil)
                isApplyingExternalText = false
                onTextChange(replacement)
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let added = (replacementString as NSString?)?.length ?? 0
            editedRange = NSRange(location: affectedCharRange.location, length: max(added, affectedCharRange.length, 1))
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, !isRestyling else { return }
            guard let textView = notification.object as? NSTextView else { return }
            // Marked Chinese (and other IME) text is still being composed. Restyling it drops the composition.
            if !textView.hasMarkedText() {
                let length = (textView.string as NSString).length
                let edited = editedRange
                editedRange = nil
                restyle(edited: edited)
                if length > EditorTypography.immediateLimit, length <= EditorTypography.stylingLimit {
                    laterRestyle?.cancel()
                    let item = DispatchWorkItem { [weak self] in
                        self?.restyle(edited: nil)
                    }
                    laterRestyle = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(280), execute: item)
                }
            }
            onTextChange(textView.string)
        }

        func restyle(edited: NSRange?) {
            guard let textView, !isRestyling, !textView.hasMarkedText() else { return }
            isRestyling = true
            defer { isRestyling = false }
            EditorTypography.apply(to: textView, monospaced: monospaced, edited: edited)
        }
    }
}

enum EditorTypography {
    static let stylingLimit = 250_000
    /// Below this size, each keystroke restyles the whole note. Above it, only the edited lines.
    static let immediateLimit = 80_000

    static func baseFont(_ style: XYZEditorStyle) -> NSFont {
        if style.monospaced {
            return NSFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
        }
        return proportional(size: style.fontSize, weight: .regular)
    }

    static func headingFont(_ style: XYZEditorStyle, level: Int) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.45
        case 2: scale = 1.26
        case 3: scale = 1.12
        default: scale = 1.04
        }
        let size = (style.fontSize * scale).rounded()
        if style.monospaced {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        }
        return proportional(size: size, weight: .semibold)
    }

    static func markerFont(_ style: XYZEditorStyle) -> NSFont {
        let size = max(12, (style.fontSize * 0.86).rounded())
        if style.monospaced {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return proportional(size: size, weight: .regular)
    }

    static func codeFont(_ style: XYZEditorStyle) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: (style.fontSize * 0.92).rounded(), weight: .regular)
    }

    static func naturalLineHeight(_ font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    /// SF Pro for Latin, PingFang SC when the primary face has no glyph.
    static func proportional(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let fallback = NSFontDescriptor(fontAttributes: [.name: "PingFang SC"])
        let descriptor = base.fontDescriptor.addingAttributes([
            .cascadeList: [fallback],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func apply(to textView: NSTextView, monospaced: Bool, edited: NSRange?) {
        guard let storage = textView.textStorage else { return }
        let style = XYZEditorStyle(monospaced: monospaced)
        let font = baseFont(style)
        let paragraph = style.paragraphStyle(naturalLineHeight: naturalLineHeight(font))
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let span = full.length > immediateLimit ? lineSpan(ns, around: edited) : full
        textView.undoManager?.disableUndoRegistration()
        storage.beginEditing()
        if span.length > 0, span.location >= 0, NSMaxRange(span) <= ns.length {
            storage.setAttributes([
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ], range: span)
            if full.length <= stylingLimit {
                styleMarkup(storage, style: style, within: span)
            }
        }
        storage.endEditing()
        textView.undoManager?.enableUndoRegistration()
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        if full.length <= immediateLimit, let manager = textView.textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
        }
    }

    private static func lineSpan(_ ns: NSString, around edited: NSRange?) -> NSRange {
        let full = NSRange(location: 0, length: ns.length)
        guard let edited, ns.length > 0 else { return full }
        let startLoc = min(max(0, edited.location), ns.length - 1)
        let endLoc = min(max(startLoc, NSMaxRange(edited) - 1), ns.length - 1)
        let start = ns.lineRange(for: NSRange(location: startLoc, length: 0))
        let end = ns.lineRange(for: NSRange(location: endLoc, length: 0))
        return NSUnionRange(start, end)
    }

    private static func styleMarkup(_ storage: NSTextStorage, style: XYZEditorStyle, within span: NSRange) {
        let ns = storage.string as NSString
        let syntax = NSColor.tertiaryLabelColor
        var inFence = fenceIsOpen(ns, before: span.location)
        var location = span.location
        let limit = min(NSMaxRange(span), ns.length)
        while location < limit {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = contentRange(ns, lineRange)
            if content.range.length > 0 {
                styleLine(
                    ns: ns,
                    content: content.text,
                    range: content.range,
                    storage: storage,
                    style: style,
                    syntax: syntax,
                    inFence: &inFence
                )
            }
            let next = NSMaxRange(lineRange)
            if next <= location || next >= limit { break }
            location = next
        }
    }

    private static func fenceIsOpen(_ ns: NSString, before location: Int) -> Bool {
        var cursor = 0
        var open = false
        while cursor < location, cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let content = contentRange(ns, line)
            if isFence(content.text) {
                open.toggle()
            }
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
        }
        return open
    }

    private static func styleLine(
        ns: NSString,
        content: String,
        range: NSRange,
        storage: NSTextStorage,
        style: XYZEditorStyle,
        syntax: NSColor,
        inFence: inout Bool
    ) {
        if isFence(content) || inFence {
            if isFence(content) {
                inFence.toggle()
                storage.addAttribute(.foregroundColor, value: syntax, range: range)
            }
            storage.addAttribute(.font, value: codeFont(style), range: range)
            return
        }

        if let heading = heading(content) {
            let hashRange = NSRange(location: range.location + heading.hashLocation, length: heading.hashLength)
            storage.addAttribute(.foregroundColor, value: syntax, range: hashRange)
            storage.addAttribute(.font, value: markerFont(style), range: hashRange)
            if heading.textLocation < heading.utf16Count {
                let textRange = NSRange(
                    location: range.location + heading.textLocation,
                    length: heading.utf16Count - heading.textLocation
                )
                storage.addAttribute(.font, value: headingFont(style, level: heading.level), range: textRange)
            }
            applyInlineCode(ns: ns, range: range, storage: storage, style: style, syntax: syntax)
            return
        }

        if let marker = leadingMarkerLength(content), marker > 0, marker <= range.length {
            storage.addAttribute(
                .foregroundColor,
                value: syntax,
                range: NSRange(location: range.location, length: marker)
            )
        }
        applyInlineCode(ns: ns, range: range, storage: storage, style: style, syntax: syntax)
    }

    private struct HeadingMatch {
        var hashLocation: Int
        var hashLength: Int
        var textLocation: Int
        var utf16Count: Int
        var level: Int
    }

    private static func heading(_ content: String) -> HeadingMatch? {
        let ns = content as NSString
        let length = ns.length
        var index = 0
        var indent = 0
        while index < length, indent < 4 {
            let character = ns.character(at: index)
            if character == 0x20 || character == 0x09 {
                indent += 1
                index += 1
            } else {
                break
            }
        }
        guard indent <= 3 else { return nil }
        let hashStart = index
        var hashes = 0
        while index < length, ns.character(at: index) == 0x23, hashes < 7 {
            hashes += 1
            index += 1
        }
        guard (1...6).contains(hashes), index < length else { return nil }
        let gap = ns.character(at: index)
        guard gap == 0x20 || gap == 0x09 else { return nil }
        return HeadingMatch(
            hashLocation: hashStart,
            hashLength: hashes,
            textLocation: index + 1,
            utf16Count: length,
            level: hashes
        )
    }

    private static func leadingMarkerLength(_ content: String) -> Int? {
        let ns = content as NSString
        let length = ns.length
        var index = 0
        var indent = 0
        while index < length, indent < 4 {
            let character = ns.character(at: index)
            if character == 0x20 || character == 0x09 {
                indent += 1
                index += 1
            } else {
                break
            }
        }
        guard index < length else { return nil }
        let character = ns.character(at: index)
        if character == 0x3E {
            while index < length {
                let mark = ns.character(at: index)
                if mark == 0x3E || mark == 0x20 {
                    index += 1
                } else {
                    break
                }
            }
            return index
        }
        if character == 0x2D || character == 0x2A || character == 0x2B {
            let next = index + 1
            guard next < length else { return nil }
            let gap = ns.character(at: next)
            guard gap == 0x20 || gap == 0x09 else { return nil }
            return next + 1
        }
        if character >= 0x30 && character <= 0x39 {
            var cursor = index
            var digits = 0
            while cursor < length, ns.character(at: cursor) >= 0x30, ns.character(at: cursor) <= 0x39, digits < 9 {
                digits += 1
                cursor += 1
            }
            guard digits > 0, cursor < length else { return nil }
            let punct = ns.character(at: cursor)
            guard punct == 0x2E || punct == 0x29 else { return nil }
            let gapIndex = cursor + 1
            guard gapIndex < length else { return nil }
            let gap = ns.character(at: gapIndex)
            guard gap == 0x20 || gap == 0x09 else { return nil }
            return gapIndex + 1
        }
        return nil
    }

    private static func isFence(_ content: String) -> Bool {
        let ns = content as NSString
        var index = 0
        var indent = 0
        while index < ns.length, indent < 4 {
            let character = ns.character(at: index)
            if character == 0x20 || character == 0x09 {
                indent += 1
                index += 1
            } else {
                break
            }
        }
        guard indent <= 3, index < ns.length else { return false }
        let marker = ns.character(at: index)
        guard marker == 0x60 || marker == 0x7E else { return false }
        var count = 0
        while index < ns.length, ns.character(at: index) == marker {
            count += 1
            index += 1
        }
        return count >= 3
    }

    private static func applyInlineCode(
        ns: NSString,
        range: NSRange,
        storage: NSTextStorage,
        style: XYZEditorStyle,
        syntax: NSColor
    ) {
        guard range.length > 1 else { return }
        let font = codeFont(style)
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            guard ns.character(at: index) == 0x60 else {
                index += 1
                continue
            }
            var ticks = 0
            while index + ticks < end, ns.character(at: index + ticks) == 0x60 {
                ticks += 1
            }
            var cursor = index + ticks
            var closed: Int?
            while cursor < end {
                if ns.character(at: cursor) == 0x60 {
                    var run = 0
                    while cursor + run < end, ns.character(at: cursor + run) == 0x60 {
                        run += 1
                    }
                    if run == ticks {
                        closed = cursor
                        break
                    }
                    cursor += run
                } else {
                    cursor += 1
                }
            }
            guard let close = closed else { break }
            let codeStart = index + ticks
            if close > codeStart {
                storage.addAttribute(.font, value: font, range: NSRange(location: codeStart, length: close - codeStart))
                storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: index, length: ticks))
                storage.addAttribute(.foregroundColor, value: syntax, range: NSRange(location: close, length: ticks))
            }
            index = close + ticks
        }
    }

    private static func contentRange(_ ns: NSString, _ lineRange: NSRange) -> (text: String, range: NSRange) {
        var range = lineRange
        if range.length > 0 {
            let last = ns.character(at: NSMaxRange(range) - 1)
            if last == 0x0A {
                range.length -= 1
                if range.length > 0, ns.character(at: NSMaxRange(range) - 1) == 0x0D {
                    range.length -= 1
                }
            } else if last == 0x0D {
                range.length -= 1
            }
        }
        return (ns.substring(with: range), range)
    }
}
#endif
