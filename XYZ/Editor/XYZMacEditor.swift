#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

/// TextKit 2 editor. Attributes are display-only: the saved value is still `string`.
final class XYZMacTextView: NSTextView {
    weak var documentUndoManager: UndoManager?
    var onAppearanceChange: (() -> Void)?
    var allowsMarkup = true
    /// The open file's language, for comment toggling.
    var sourceLanguage: SyntaxLanguage = .plain
    /// Size and measure from Settings. Layout derives the side padding from it.
    var style = XYZEditorStyle() {
        didSet {
            if showsLineNumbers, style != oldValue {
                editorPane?.gutter.needsDisplay = true
            }
        }
    }
    /// Settings → Show line numbers. The gutter is a sibling of the scroll view, not a subview of it.
    var showsLineNumbers = false {
        didSet {
            guard showsLineNumbers != oldValue else { return }
            editorPane?.gutter.invalidateLines()
            editorPane?.needsLayout = true
            needsLayout = true
        }
    }
    /// The pane that owns this text view and its gutter. Set when the pane attaches the document.
    weak var editorPane: EditorPane?
    /// The live gutter, for the offscreen snapshot. Nil until line numbers are turned on.
    var lineNumberGutter: LineNumberGutter? {
        guard showsLineNumbers, let gutter = editorPane?.gutter, gutter.superview != nil, !gutter.isHidden else {
            return nil
        }
        return gutter
    }
    /// Restored once, after the view is in a window and the inset matches the pane.
    private var pendingAnchor: EditorScrollAnchor?
    private var isAligning = false

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
        return super.performKeyEquivalent(with: event)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action, LineEditMenu.actions.contains(action) {
            guard isEditable else { return false }
            if action == #selector(xyzToggleComment(_:)) {
                return TextTransforms.lineComment(for: sourceLanguage) != nil
            }
            if action == #selector(xyzMakeUppercase(_:))
                || action == #selector(xyzMakeLowercase(_:))
                || action == #selector(xyzMakeTitleCase(_:)) {
                return selectedRange().length > 0
            }
            return true
        }
        return super.validateMenuItem(menuItem)
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

    func sourceSelection() -> SourceRange {
        let range = selectedRange()
        return SourceRange(location: range.location, length: range.length)
    }

    @discardableResult
    func applyMarkupEdit(_ edit: SourceReplacement?) -> Bool {
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

    /// One replacement, one undo group. Used for find-and-replace and line edits on every text file.
    @discardableResult
    func applySourceEdit(_ edit: SourceReplacement?) -> Bool {
        guard isEditable, !hasMarkedText(), let edit, let storage = textStorage else { return false }
        let range = NSRange(location: edit.range.location, length: edit.range.length)
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        guard shouldChangeText(in: range, replacementString: edit.text) else { return false }
        storage.replaceCharacters(in: range, with: edit.text)
        didChangeText()
        let length = (string as NSString).length
        let location = min(max(0, edit.selection.location), length)
        let selectionLength = min(max(0, edit.selection.length), max(length - location, 0))
        setSelectedRange(NSRange(location: location, length: selectionLength))
        return true
    }

    @objc func xyzDuplicateLineDown(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.duplicateLine(in: string, selection: sourceSelection(), above: false))
    }

    @objc func xyzDuplicateLineUp(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.duplicateLine(in: string, selection: sourceSelection(), above: true))
    }

    @objc func xyzMoveLineDown(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.moveLine(in: string, selection: sourceSelection(), up: false))
    }

    @objc func xyzMoveLineUp(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.moveLine(in: string, selection: sourceSelection(), up: true))
    }

    @objc func xyzDeleteLine(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.deleteLine(in: string, selection: sourceSelection()))
    }

    @objc func xyzIndentLines(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.indentLines(in: string, selection: sourceSelection(), outdent: false))
    }

    @objc func xyzOutdentLines(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.indentLines(in: string, selection: sourceSelection(), outdent: true))
    }

    @objc func xyzToggleComment(_ sender: Any?) {
        guard let prefix = TextTransforms.lineComment(for: sourceLanguage) else { return }
        let suffix = TextTransforms.lineCommentSuffix(for: sourceLanguage)
        _ = applySourceEdit(TextTransforms.toggleComment(in: string, selection: sourceSelection(), prefix: prefix, suffix: suffix))
    }

    @objc func xyzJoinLines(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.joinLines(in: string, selection: sourceSelection()))
    }

    @objc func xyzSortLines(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.sortLines(in: string, selection: sourceSelection()))
    }

    @objc func xyzTrimTrailingWhitespace(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.trimTrailingWhitespace(in: string, selection: sourceSelection()))
    }

    @objc func xyzMakeUppercase(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.transformCase(in: string, selection: sourceSelection(), style: .upper))
    }

    @objc func xyzMakeLowercase(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.transformCase(in: string, selection: sourceSelection(), style: .lower))
    }

    @objc func xyzMakeTitleCase(_ sender: Any?) {
        _ = applySourceEdit(TextTransforms.transformCase(in: string, selection: sourceSelection(), style: .title))
    }

    override func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        let useSelection = tag == NSTextFinder.Action.setSearchString.rawValue
            || tag == Int(NSFindPanelAction.setFindString.rawValue)
        if useSelection {
            findAction?(.useSelection)
            return
        }
        super.performFindPanelAction(sender)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), event.clickCount == 1, isEditable {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            guard index != NSNotFound else {
                super.mouseDown(with: event)
                return
            }
            var ranges = selectedRanges.compactMap { ($0 as? NSValue)?.rangeValue }
            ranges.append(NSRange(location: index, length: 0))
            selectedRanges = ranges.map { NSValue(range: $0) }
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let ranges = selectedRanges.compactMap { ($0 as? NSValue)?.rangeValue }
        guard ranges.count > 1, let text = insertString as? String, replacementRange.location == NSNotFound else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        undoManager?.beginUndoGrouping()
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            super.insertText(text, replacementRange: range)
        }
        undoManager?.endUndoGrouping()
    }

    weak var findModel: EditorFindModel?
    var findAction: ((FindBarAction) -> Void)?

    func runFind(_ action: FindBarAction) {
        guard let model = findModel else { return }
        switch action {
        case .refresh:
            scheduleReveal(model, forward: true, stayIfAlreadyThere: true)
        case .next:
            revealCached(model, forward: true, stayIfAlreadyThere: false)
        case .previous:
            revealCached(model, forward: false, stayIfAlreadyThere: false)
        case .replaceOne:
            replaceCurrent(model)
        case .replaceAll:
            replaceEvery(model)
        case .useSelection:
            let selected = sourceSelection()
            guard selected.length > 0 else { return }
            let ns = string as NSString
            model.pattern = ns.substring(with: NSRange(location: selected.location, length: selected.length))
            model.visible = true
            model.scheduleRefresh()
        case .selectNextOccurrence:
            selectNextOccurrence()
        case .focus:
            model.focusToken &+= 1
        case .cancel:
            findTask?.cancel()
            findGeneration += 1
        }
    }

    private var findTask: Task<Void, Never>?
    private var findGeneration = 0
    private var cachedQuery: FindQuery?
    private var cachedMatches: [FindMatch] = []

    /// Counts matches off the main thread. A newer keystroke cancels this pass.
    private func scheduleReveal(_ model: EditorFindModel, forward: Bool, stayIfAlreadyThere: Bool) {
        findTask?.cancel()
        let text = string
        let query = model.query
        let selection = sourceSelection()
        findGeneration += 1
        let token = findGeneration
        findTask = Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                FindScan.make(text: text, query: query, selection: selection, forward: forward, stay: stayIfAlreadyThere)
            }.value
            await MainActor.run { [weak self] in
                guard let self, token == self.findGeneration else { return }
                self.apply(scanned, model: model, query: query)
            }
        }
    }

    private func revealCached(_ model: EditorFindModel, forward: Bool, stayIfAlreadyThere: Bool) {
        guard cachedQuery == model.query else {
            scheduleReveal(model, forward: forward, stayIfAlreadyThere: stayIfAlreadyThere)
            return
        }
        apply(FindScan.pick(text: string, matches: cachedMatches, query: model.query, selection: sourceSelection(), forward: forward, stay: stayIfAlreadyThere), model: model, query: model.query)
    }

    private func apply(_ scanned: FindScan, model: EditorFindModel, query: FindQuery) {
        cachedQuery = query
        cachedMatches = scanned.matches
        model.count = scanned.count
        model.regexInvalid = scanned.invalid
        model.index = scanned.index
        guard let range = scanned.range else { return }
        let nsRange = NSRange(location: range.location, length: range.length)
        setSelectedRange(nsRange)
        reveal(EditorScrollAnchor(fraction: 0, probe: "", line: scanned.line))
    }

    private func revealMatch(_ model: EditorFindModel, forward: Bool, stayIfAlreadyThere: Bool) {
        scheduleReveal(model, forward: forward, stayIfAlreadyThere: stayIfAlreadyThere)
    }

/// A find pass. The heavy scan runs off the main thread.
private struct FindScan {
    var matches: [FindMatch]
    var count: Int
    var index: Int
    var invalid: Bool
    var range: SourceRange?
    var line: Int

    static func make(text: String, query: FindQuery, selection: SourceRange, forward: Bool, stay: Bool) -> FindScan {
        let result = TextFind.scan(text: text, query: query, selection: selection, forward: forward, stay: stay)
        return FindScan(
            matches: result.matches,
            count: result.count,
            index: result.index,
            invalid: result.invalid,
            range: result.range,
            line: result.line
        )
    }

    static func pick(
        text: String,
        matches: [FindMatch],
        query: FindQuery,
        selection: SourceRange,
        forward: Bool,
        stay: Bool
    ) -> FindScan {
        let invalid = !query.pattern.isEmpty && !TextFind.isValid(query)
        guard !matches.isEmpty else {
            return FindScan(matches: matches, count: 0, index: 0, invalid: invalid, range: nil, line: 1)
        }
        let index: Int
        if stay, let current = matches.firstIndex(where: {
            $0.range.location == selection.location && $0.range.length == selection.length
        }) {
            index = current
        } else if let stepped = TextFind.step(from: selection, matches: matches, forward: forward) {
            index = stepped
        } else {
            index = 0
        }
        let range = matches[index].range
        return FindScan(
            matches: matches,
            count: matches.count,
            index: index + 1,
            invalid: invalid,
            range: range,
            line: TextFind.lineNumber(in: text, utf16: range.location)
        )
    }
}

    private func replaceCurrent(_ model: EditorFindModel) {
        guard isEditable else { return }
        var matches = TextFind.matches(in: string, query: model.query)
        var selection = sourceSelection()
        var index = matches.firstIndex(where: {
            $0.range.location == selection.location && $0.range.length == selection.length
        })
        if index == nil {
            revealMatch(model, forward: true, stayIfAlreadyThere: false)
            matches = TextFind.matches(in: string, query: model.query)
            selection = sourceSelection()
            index = matches.firstIndex(where: {
                $0.range.location == selection.location && $0.range.length == selection.length
            })
        }
        guard let index else { return }
        let match = matches[index]
        let piece = model.replacementText(for: string, match: match)
        guard applySourceEdit(SourceReplacement(
            range: match.range,
            text: piece,
            selection: SourceRange(location: match.range.location, length: (piece as NSString).length)
        )) else { return }
        revealMatch(model, forward: true, stayIfAlreadyThere: false)
    }

    private func replaceEvery(_ model: EditorFindModel) {
        guard isEditable else { return }
        let replaced = TextFind.replaceAll(in: string, query: model.query, with: model.replacement)
        guard replaced.count > 0 else { return }
        let full = SourceRange(location: 0, length: (string as NSString).length)
        _ = applySourceEdit(SourceReplacement(
            range: full,
            text: replaced.text,
            selection: SourceRange(location: 0, length: 0)
        ))
        revealMatch(model, forward: true, stayIfAlreadyThere: true)
    }

    func selectNextOccurrence() {
        let ns = string as NSString
        let current = selectedRanges.compactMap { ($0 as? NSValue)?.rangeValue }.sorted { $0.location < $1.location }
        let seedRange = current.last(where: { $0.length > 0 }) ?? current.last
        let seed: String
        if let seedRange, seedRange.length > 0 {
            seed = ns.substring(with: seedRange)
        } else {
            let origin = seedRange?.location ?? selectedRange().location
            let word = ns.rangeOfCharacter(from: .alphanumerics.inverted, options: .backwards, range: NSRange(location: 0, length: origin))
            let start = word.location == NSNotFound ? 0 : NSMaxRange(word)
            let forward = ns.rangeOfCharacter(from: .alphanumerics.inverted, options: [], range: NSRange(location: origin, length: ns.length - origin))
            let end = forward.location == NSNotFound ? ns.length : forward.location
            guard end > start else { return }
            seed = ns.substring(with: NSRange(location: start, length: end - start))
            setSelectedRange(NSRange(location: start, length: end - start))
        }
        guard !seed.isEmpty else { return }
        let matches = TextFind.matches(in: string, query: FindQuery(pattern: seed, matchCase: true))
        let after = current.last?.location ?? 0
        guard let next = matches.first(where: { $0.range.location > after }) ?? matches.first(where: { $0.range.location != after }) else { return }
        var ranges = current.filter { $0.length > 0 }
        if ranges.isEmpty, let seedRange {
            ranges = [seedRange]
        }
        let added = NSRange(location: next.range.location, length: next.range.length)
        if !ranges.contains(where: { NSEqualRanges($0, added) }) {
            ranges.append(added)
        }
        selectedRanges = ranges.map { NSValue(range: $0) }
        scrollRangeToVisible(added)
    }

    override func layout() {
        super.layout()
        guard !isAligning else { return }
        guard let width = enclosingScrollView?.contentSize.width, width > 1 else { return }
        textContainer?.lineFragmentPadding = 0
        enclosingScrollView?.rulersVisible = false
        let next = expectedInset(for: width)
        if textContainerInset != next {
            textContainerInset = next
            needsLayout = true
            return
        }
        editorPane?.noteTextLayout()
        clampToClip()
        alignIfReady()
    }

    /// A short note is stretched to the clip. The insets were added again, so the text view
    /// stuck about 18 points past the window. Long notes stay taller than the clip and scroll.
    private func clampToClip() {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView.bounds.height
        guard clip > 1, bounds.height > clip else { return }
        let extra = bounds.height - clip
        guard extra <= textContainerInset.height * 2 + 6 else { return }
        setFrameSize(NSSize(width: bounds.width, height: clip))
    }

    /// Turns numbers on or off on this view. Called from SwiftUI updates, including a mode
    /// change on a text view that is already on screen.
    func syncLineNumbers(_ show: Bool) {
        if showsLineNumbers != show {
            showsLineNumbers = show
            showViewport()
        } else if show {
            editorPane?.needsLayout = true
            editorPane?.gutter.needsDisplay = true
        }
    }

    /// TextKit 2 only draws the laid-out viewport. A mode change has to ask for it again.
    func showViewport() {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        needsDisplay = true
        enclosingScrollView?.needsDisplay = true
    }

    /// The side padding from Settings. Line numbers live in the sibling gutter, not in this inset.
    private func expectedInset(for paneWidth: CGFloat) -> NSSize {
        NSSize(width: style.sideInset(for: paneWidth), height: style.verticalInset)
    }

    /// The text changed: renumber. A wider number asks the pane to grow the gutter.
    func lineNumbersChanged() {
        guard showsLineNumbers else { return }
        editorPane?.gutter.invalidateLines()
        editorPane?.needsLayout = true
    }

    /// The caret's number is darker, and Editing draws a band behind that line.
    func caretMoved() {
        if showsLineNumbers {
            editorPane?.gutter.needsDisplay = true
        }
        guard isEditable else { return }
        guard let band = currentLineBand() else { return }
        if let previous = lastLineBand, !previous.equalTo(band) {
            setNeedsDisplay(previous)
        }
        lastLineBand = band
        setNeedsDisplay(band)
    }

    private var lastLineBand: NSRect?
    private var lineIndexCache: LineIndex?
    private var lineIndexToken = 0

    /// Line starts for the status bar. Built off the main thread so closing find does not scan the file.
    func warmLineIndex() {
        lineIndexToken += 1
        let token = lineIndexToken
        let text = string
        Task.detached(priority: .utility) { [weak self] in
            let index = LineIndex(text)
            await MainActor.run { [weak self] in
                guard let self, token == self.lineIndexToken else { return }
                self.lineIndexCache = index
            }
        }
    }

    func cachedLineIndex() -> LineIndex? {
        lineIndexCache
    }

    /// The current line, already laid out. Does not ask TextKit to lay out the rest of the file.
    private func currentLineBand() -> NSRect? {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return nil }
        let length = (string as NSString).length
        let clamped = min(max(0, selectedRange().location), length)
        guard let start = content.location(content.documentRange.location, offsetBy: clamped),
              let fragment = manager.textLayoutFragment(for: start) else { return nil }
        return NSRect(
            x: 0,
            y: textContainerOrigin.y + fragment.layoutFragmentFrame.minY,
            width: bounds.width,
            height: fragment.layoutFragmentFrame.height
        )
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard isEditable, let manager = textLayoutManager, let content = manager.textContentManager else { return }
        let document = content.documentRange
        let length = (string as NSString).length
        let clamped = min(max(0, selectedRange().location), length)
        guard let start = content.location(document.location, offsetBy: clamped),
              let fragment = manager.textLayoutFragment(for: start) else { return }
        let lineTop = textContainerOrigin.y + fragment.layoutFragmentFrame.minY
        let full = NSRect(
            x: -textContainerOrigin.x,
            y: lineTop,
            width: bounds.width + textContainerOrigin.x,
            height: fragment.layoutFragmentFrame.height
        )
        let paint = full.intersection(rect.insetBy(dx: -textContainerOrigin.x, dy: 0))
        guard !paint.isNull, paint.width > 0, paint.height > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        paint.fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        layoutSubtreeIfNeeded()
        alignIfReady()
    }

    func scrollAnchor() -> EditorScrollAnchor {
        guard let scroll = enclosingScrollView else {
            ViewAnchorLog.captured(from: "source", line: 1)
            return EditorScrollAnchor(fraction: 0, probe: "", line: 1)
        }
        let visible = scroll.contentView.bounds
        let span = max(bounds.height - visible.height, 1)
        let fraction = min(1, max(0, visible.origin.y / span))
        let line = viewportTopLine()
        ViewAnchorLog.captured(from: "source", line: line)
        let ns = string as NSString
        let location = min(max(0, EditorScrollAnchor.utf16Location(ofLine: line, in: string)), max(ns.length - 1, 0))
        guard ns.length > 0 else {
            return EditorScrollAnchor(fraction: fraction, probe: "", line: line)
        }
        let range = ns.lineRange(for: NSRange(location: location, length: 0))
        var content = range
        if content.length > 0 {
            let last = ns.character(at: NSMaxRange(content) - 1)
            if last == 0x0A || last == 0x0D {
                content.length -= 1
            }
        }
        let probe = EditorScrollAnchor.probe(from: ns.substring(with: content))
        return EditorScrollAnchor(fraction: fraction, probe: probe, line: line)
    }

    /// Go to Heading, or Go to Line. The caret sits on that line and column, and the line is at the top.
    func jump(toLine line: Int, column: Int = 1, selecting needle: String? = nil) {
        let length = (string as NSString).length
        let location = min(max(0, GoToPosition.utf16Offset(in: string, line: line, column: column)), length)
        if let needle, !needle.isEmpty {
            select(needle, onLineAt: location)
        } else {
            setSelectedRange(NSRange(location: location, length: 0))
        }
        window?.makeFirstResponder(self)
        reveal(EditorScrollAnchor(fraction: 0, probe: "", line: line))
    }

    /// Selects the first case-insensitive match on the line. The caret stays on the line when there is none.
    private func select(_ needle: String, onLineAt location: Int) {
        let ns = string as NSString
        guard ns.length > 0 else { return }
        let probe = min(max(0, location), ns.length - 1)
        let lineRange = ns.lineRange(for: NSRange(location: probe, length: 0))
        let found = ns.range(of: needle, options: [.caseInsensitive], range: lineRange)
        if found.location != NSNotFound {
            setSelectedRange(found)
        } else {
            setSelectedRange(NSRange(location: min(location, ns.length), length: 0))
        }
    }

    /// Remember the line and align on the next layout that has a window and a real inset.
    /// One scroll. `scrollRangeToVisible` is not used: it only guarantees the line is somewhere in view.
    func reveal(_ anchor: EditorScrollAnchor) {
        pendingAnchor = anchor
        if window != nil {
            layoutSubtreeIfNeeded()
            alignIfReady()
        }
    }

    private func alignIfReady() {
        guard let anchor = pendingAnchor, !isAligning, window != nil else { return }
        guard let scroll = enclosingScrollView, scroll.contentSize.width > 1, bounds.width > 1 else { return }
        guard textContainerInset == expectedInset(for: scroll.contentSize.width) else { return }
        pendingAnchor = nil
        scrollLineToTop(anchor)
    }

    /// Lay out from the start of the document through the target line, then put that line
    /// where the first line sits: viewport top plus `textContainerInset`.
    private func scrollLineToTop(_ anchor: EditorScrollAnchor) {
        isAligning = true
        defer { isAligning = false }
        let length = (string as NSString).length
        let location = min(max(0, anchor.utf16Location(in: string)), length)
        let requested = anchor.line > 0 ? anchor.line : EditorScrollAnchor.lineNumber(at: location, in: string)
        guard let scroll = enclosingScrollView else {
            ViewAnchorLog.aligned(to: "source", requested: requested, landed: requested)
            return
        }
        var y = lineOffset(utf16: location) ?? 0
        let visible = max(scroll.contentView.bounds.height, 1)
        if bounds.height < y + visible, let manager = textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
            let used = manager.usageBoundsForTextContainer
            let fitted = ceil(used.maxY + textContainerInset.height * 2)
            let needed = max(fitted, y + visible)
            if bounds.height + 1 < needed {
                setFrameSize(NSSize(width: bounds.width, height: needed))
            }
            y = lineOffset(utf16: location) ?? y
        }
        let maxY = max(0, bounds.height - scroll.contentView.bounds.height)
        let target = min(max(0, y), maxY)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        NSAnimationContext.endGrouping()
        ViewAnchorLog.aligned(to: "source", requested: requested, landed: viewportTopLine())
    }

    /// Distance from the top of the text view to the line, minus the inset.
    /// That is the clip origin that leaves the inset above the line, matching a document opened at the top.
    private func lineOffset(utf16: Int) -> CGFloat? {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return nil }
        let document = content.documentRange
        let length = (string as NSString).length
        let clamped = min(max(0, utf16), length)
        let start = content.location(document.location, offsetBy: clamped) ?? document.location
        let end = content.location(start, offsetBy: 1) ?? document.endLocation
        // Failable on the 27.1 SDK, non-optional on 26.6. The annotation accepts both.
        let layoutRange: NSTextRange? = NSTextRange(location: document.location, end: end)
        if let layoutRange {
            manager.ensureLayout(for: layoutRange)
        } else {
            manager.textViewportLayoutController.layoutViewport()
        }
        let fragment = manager.textLayoutFragment(for: start)
            ?? (clamped > 0 ? content.location(document.location, offsetBy: clamped - 1).flatMap { manager.textLayoutFragment(for: $0) } : nil)
        guard let fragment else { return 0 }
        let lineTop = textContainerOrigin.y + fragment.layoutFragmentFrame.minY
        return lineTop - textContainerInset.height
    }

    /// The source line whose top is at the viewport's content top.
    /// Uses the same fragment frame as `lineOffset`, so capture and restore name one line.
    private func viewportTopLine() -> Int {
        guard let manager = textLayoutManager,
              let content = manager.textContentManager else { return 1 }
        // Walking from the start with `.ensuresLayout` lays out the whole file and, on macOS 27,
        // leaves the viewport with nothing to draw.
        let viewport = manager.textViewportLayoutController
        viewport.layoutViewport()
        guard let location = viewport.viewportRange?.location else { return 1 }
        let offset = content.offset(from: content.documentRange.location, to: location)
        if let index = lineIndexCache {
            return max(1, index.line(at: max(0, offset)))
        }
        return max(1, EditorScrollAnchor.lineNumber(at: max(0, offset), in: string))
    }

    /// The first source line already in the viewport. Does not lay out the rest of the file.
    func viewportLine() -> Int? {
        guard let manager = textLayoutManager,
              let content = manager.textContentManager,
              let location = manager.textViewportLayoutController.viewportRange?.location,
              let index = lineIndexCache else { return nil }
        let offset = content.offset(from: content.documentRange.location, to: location)
        return max(1, index.line(at: max(0, offset)))
    }
}

/// The editor scroller. Line numbers are not a subview of this view: `NSScrollView` would cover them.
final class EditorScrollView: NSScrollView {}

/// Gutter and scroller, side by side. The pair stops at the top of the status bar.
final class EditorPane: NSView {
    let gutter = LineNumberGutter()
    let scrollView = EditorScrollView()
    private var clamping = false
    private var scrollObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        gutter.translatesAutoresizingMaskIntoConstraints = true
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(gutter)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    func attach(_ textView: XYZMacTextView) {
        textView.editorPane = self
        gutter.textView = textView
        scrollView.documentView = textView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in
                self?.gutter.needsDisplay = true
            }
        }
        needsLayout = true
    }

    func noteTextLayout() {
        // Display only. Marking the pane dirty from the text view's layout never finishes.
        gutter.needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard !clamping else { return }
        clamping = true
        clampAboveStatusBar()
        clamping = false
        let show = gutter.textView?.showsLineNumbers == true
        gutter.isHidden = !show
        let width: CGFloat
        if show, let textView = gutter.textView {
            width = max(36, gutter.numberWidth(fontSize: textView.style.fontSize) + 16)
        } else {
            width = 0
        }
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(1, bounds.width - width), height: bounds.height)
        gutter.needsDisplay = true
    }

    /// The hosting view includes the status bar. Keep this pane above that bar.
    private func clampAboveStatusBar() {
        guard let content = window?.contentView, let parent = superview else { return }
        guard let bar = Self.statusBar(in: content) else { return }
        let barBox = bar.convert(bar.bounds, to: content)
        var mine = convert(bounds, to: content)
        // The window content view is not flipped: smaller y is lower on screen.
        let overlap = barBox.maxY - mine.minY
        guard overlap > 0.5, mine.height - overlap > 1 else { return }
        mine.origin.y += overlap
        mine.size.height -= overlap
        let next = content.convert(mine, to: parent)
        guard next.height > 1, next != frame else { return }
        frame = next
    }

    private static func statusBar(in root: NSView) -> NSView? {
        if root.identifier?.rawValue == "xyz.statusBar" { return root }
        for child in root.subviews {
            if let found = statusBar(in: child) { return found }
        }
        return nil
    }
}

struct XYZMacEditor: NSViewRepresentable {
    var text: String
    var isEditable: Bool
    var undoManager: UndoManager?
    var reloadToken: Int
    var style: XYZEditorStyle
    var scrollLink: EditorScrollLink
    var markup: Bool
    var spellCheck: Bool
    var syntax: SyntaxLanguage
    var lineNumbers: Bool
    var find: EditorFindModel?
    var onSelection: ((EditorCaret) -> Void)?
    var onTextChange: (String) -> Void

    func makeNSView(context: Context) -> EditorPane {
        let textView = XYZMacTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = spellCheck
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        // The clip view's background layer sits over TextKit 2 fragments once the gutter is added.
        textView.clipsToBounds = true
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.isVerticallyResizable = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel(String(localized: "Markdown editor"))

        context.coordinator.textView = textView
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onSelection = onSelection
        context.coordinator.style = style
        context.coordinator.syntax = syntax
        textView.allowsMarkup = markup
        textView.delegate = context.coordinator
        textView.documentUndoManager = undoManager
        textView.onAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.restyle(edited: nil)
        }

        let pane = EditorPane()
        let scrollView = pane.scrollView
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
        // The clip view's background layer sits over TextKit 2 fragments. The text view paints
        // the canvas itself.
        scrollView.clipsToBounds = true
        scrollView.contentView.clipsToBounds = true
        scrollView.contentView.drawsBackground = false
        pane.attach(textView)
        textView.syncLineNumbers(lineNumbers)
        applyChrome(textView: textView, scrollView: scrollView, style: style)
        textView.string = text
        textView.warmLineIndex()
        context.coordinator.restyle(edited: nil)
        context.coordinator.observeScroll(of: scrollView)
        applyWrap(textView: textView, scrollView: scrollView, wraps: style.wraps)
        textView.layoutManager?.allowsNonContiguousLayout = true
        assert(textView.textLayoutManager != nil, "XYZEditor requires TextKit 2")
        return pane
    }

    func updateNSView(_ pane: EditorPane, context: Context) {
        let scrollView = pane.scrollView
        guard let textView = scrollView.documentView as? XYZMacTextView else { return }
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onSelection = onSelection
        context.coordinator.scrollLink = scrollLink
        let editingChanged = textView.isEditable != isEditable
        textView.isEditable = isEditable
        if editingChanged {
            textView.showViewport()
            if !isEditable {
                context.coordinator.forgetViewportLine()
            }
        }
        let markupChanged = textView.allowsMarkup != markup
        textView.allowsMarkup = markup
        if textView.isContinuousSpellCheckingEnabled != spellCheck {
            textView.isContinuousSpellCheckingEnabled = spellCheck
        }
        textView.syncLineNumbers(lineNumbers)
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.scrollerInsets = NSEdgeInsets()
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = NSEdgeInsets()
        scrollView.clipsToBounds = true
        scrollView.contentView.clipsToBounds = true
        scrollView.contentView.drawsBackground = false
        textView.documentUndoManager = undoManager
        scrollLink.capture = { [weak textView] in
            textView?.scrollAnchor() ?? EditorScrollAnchor(fraction: 0, probe: "", line: 1)
        }
        scrollLink.revealLine = { [weak textView] line in
            textView?.jump(toLine: line)
        }
        scrollLink.revealMatch = { [weak textView] line, needle in
            textView?.jump(toLine: line, selecting: needle)
        }
        scrollLink.revealPosition = { [weak textView] line, column in
            textView?.jump(toLine: line, column: column)
        }
        scrollLink.focusEditor = { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
        }
        textView.findModel = find
        textView.sourceLanguage = syntax
        find?.language = syntax
        find?.perform = { [weak textView] action in
            textView?.runFind(action)
        }
        find?.edit = { [weak textView] make in
            guard let textView else { return }
            textView.applySourceEdit(make(textView.string, textView.sourceSelection()))
        }
        textView.findAction = { [weak textView] action in
            textView?.runFind(action)
        }
        let previous = context.coordinator.style
        let syntaxChanged = context.coordinator.syntax != syntax
        context.coordinator.syntax = syntax
        if previous != style {
            context.coordinator.style = style
            applyChrome(textView: textView, scrollView: scrollView, style: style)
            if previous.wraps != style.wraps {
                applyWrap(textView: textView, scrollView: scrollView, wraps: style.wraps)
            }
            // Size, face, and wrap change the line boxes. Color and heading sizes follow once.
            let metrics = previous.fontSize != style.fontSize
                || previous.monospaced != style.monospaced
                || previous.lineHeight != style.lineHeight
                || previous.wraps != style.wraps
            if metrics {
                context.coordinator.applyMetrics()
                context.coordinator.scheduleRecolor()
            }
        }
        if context.coordinator.reloadToken != reloadToken {
            context.coordinator.reloadToken = reloadToken
            context.coordinator.forgetViewportLine()
            if textView.string != text {
                context.coordinator.perform(.replaceContents(text))
            } else if markupChanged || syntaxChanged {
                context.coordinator.restyle(edited: nil)
            }
        } else if markupChanged || syntaxChanged {
            context.coordinator.restyle(edited: nil)
        }
        if let anchor = scrollLink.take(for: .source) {
            textView.reveal(anchor)
        }
        if let queued = scrollLink.takeQueuedEditorReveal() {
            textView.jump(toLine: queued.line, column: queued.column, selecting: queued.needle)
        }
        if !isEditable {
            context.coordinator.publishViewportLine()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorPane, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 1 ? $0 : nil } ?? 640
        let offered = proposal.height ?? nsView.bounds.height
        let height = offered.isFinite && offered > 1 ? offered : 480
        return CGSize(width: width, height: height)
    }

    private func applyChrome(textView: XYZMacTextView, scrollView: NSScrollView, style: XYZEditorStyle) {
        textView.style = style
        textView.needsLayout = true
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
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.clipsToBounds = true
        scrollView.contentView.clipsToBounds = true
        scrollView.contentView.drawsBackground = false
    }

    /// Wrap tracks the pane. With wrap off, the line keeps its length and the pane scrolls sideways.
    private func applyWrap(textView: XYZMacTextView, scrollView: NSScrollView, wraps: Bool) {
        textView.textContainer?.widthTracksTextView = wraps
        textView.isHorizontallyResizable = !wraps
        scrollView.hasHorizontalScroller = !wraps
        scrollView.horizontalScrollElasticity = .none
        if wraps {
            textView.autoresizingMask = [.width]
            let width = max(scrollView.contentSize.width, 1)
            textView.setFrameSize(NSSize(width: width, height: max(textView.bounds.height, 1)))
            textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.autoresizingMask = [.width, .height]
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, XYZTextEditing {
        var textView: XYZMacTextView?
        var onTextChange: (String) -> Void = { _ in }
        var onSelection: ((EditorCaret) -> Void)?
        var scrollLink: EditorScrollLink?
        var reloadToken = 0
        var style = XYZEditorStyle()
        var syntax = SyntaxLanguage.plain
        private var isApplyingExternalText = false
        private var isRestyling = false
        private var editedRange: NSRange?
        private var laterRestyle: DispatchWorkItem?
        private var metricRecolor: DispatchWorkItem?
        private var scrollObserver: NSObjectProtocol?
        private var scrollRecolor: DispatchWorkItem?
        private var publishedViewportLine = 0

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        /// A large file is colored as it scrolls. Small files are already colored in full.
        func observeScroll(of scrollView: NSScrollView) {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { () -> Void in
                    self?.scheduleVisibleRecolor()
                    self?.publishViewportLine()
                }
            }
        }

        func forgetViewportLine() {
            publishedViewportLine = 0
        }

        /// Reading source follows the line on screen. Editing keeps the caret.
        func publishViewportLine() {
            guard let textView, !textView.isEditable, let scrollLink else { return }
            guard let line = textView.viewportLine(), line != publishedViewportLine else { return }
            publishedViewportLine = line
            scrollLink.onViewportLine?(line)
        }

        private func scheduleVisibleRecolor() {
            guard let textView else { return }
            guard (textView.string as NSString).length > EditorTypography.immediateLimit else { return }
            scrollRecolor?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.restyle(edited: nil)
            }
            scrollRecolor = item
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40), execute: item)
        }

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
                textView.undoManager?.disableUndoRegistration()
                textView.string = replacement
                textView.undoManager?.enableUndoRegistration()
                laterRestyle?.cancel()
                textView.warmLineIndex()
                isApplyingExternalText = false
                let visible = EditorTypography.visibleSpan(in: textView)
                DispatchQueue.main.async { [weak self] in
                    self?.restyle(edited: visible)
                }
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

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? XYZMacTextView else { return }
            textView.caretMoved()
            reportSelection(textView)
        }

        private func reportSelection(_ textView: NSTextView) {
            guard let textView = textView as? XYZMacTextView, let index = textView.cachedLineIndex() else { return }
            let range = textView.selectedRange()
            onSelection?(EditorCaret.measure(
                text: textView.string,
                utf16Location: range.location,
                utf16Length: range.length,
                index: index
            ))
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

        /// Font, line box, and wrap. One attribute pass, then the viewport lays itself out.
        func applyMetrics() {
            guard let textView, !textView.hasMarkedText() else { return }
            isRestyling = true
            defer { isRestyling = false }
            EditorTypography.applyMetrics(to: textView, style: style)
            textView.lineNumbersChanged()
        }

        /// Heading sizes and syntax colors after the last size step, not on every ⌘−.
        func scheduleRecolor() {
            metricRecolor?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.textView?.hasMarkedText() == true {
                    self.scheduleRecolor()
                    return
                }
                self.restyle(edited: nil)
            }
            metricRecolor = item
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: item)
        }

        func restyle(edited: NSRange?) {
            guard let textView, !isRestyling, !textView.hasMarkedText() else { return }
            isRestyling = true
            defer { isRestyling = false }
            EditorTypography.apply(
                to: textView,
                style: style,
                markup: textView.allowsMarkup,
                language: syntax,
                edited: edited
            )
            textView.lineNumbersChanged()
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

    /// Base font and line height everywhere; heading sizes and tinted markers only when `markup` is on.
    static func apply(
        to textView: NSTextView,
        style: XYZEditorStyle,
        markup: Bool,
        language: SyntaxLanguage = .plain,
        edited: NSRange?
    ) {
        guard let storage = textView.textStorage else { return }
        let font = baseFont(style)
        let paragraph = style.paragraphStyle(naturalLineHeight: naturalLineHeight(font))
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let span: NSRange
        if full.length > immediateLimit {
            let focus = lineSpan(ns, around: edited ?? visibleSpan(in: textView))
            span = expanded(focus, in: ns, pad: 2_000)
        } else {
            span = full
        }
        textView.undoManager?.disableUndoRegistration()
        storage.beginEditing()
        if span.length > 0, span.location >= 0, NSMaxRange(span) <= ns.length {
            storage.setAttributes([
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ], range: span)
            if markup, full.length <= stylingLimit {
                styleMarkup(storage, style: style, within: span)
            } else if !markup, language != .plain, language != .markdown,
                      full.length <= stylingLimit || span.length <= 64_000 {
                // A multi-megabyte file is not scanned from the top. The span is the visible lines.
                styleSyntax(storage, style: style, language: language, within: span)
            }
        }
        storage.endEditing()
        textView.undoManager?.enableUndoRegistration()
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        keepViewportLayout(textView)
    }

    /// The size change itself. Colors and heading sizes are a later pass.
    /// Laying out `documentRange` here turns viewport layout off for good, so later typing lays out the whole note.
    static func applyMetrics(to textView: NSTextView, style: XYZEditorStyle) {
        guard let storage = textView.textStorage else { return }
        let font = baseFont(style)
        let paragraph = style.paragraphStyle(naturalLineHeight: naturalLineHeight(font))
        let full = NSRange(location: 0, length: storage.length)
        textView.undoManager?.disableUndoRegistration()
        storage.beginEditing()
        if full.length > 0 {
            storage.addAttribute(.font, value: font, range: full)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: full)
        }
        storage.endEditing()
        textView.undoManager?.enableUndoRegistration()
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        keepViewportLayout(textView, displayViewport: true)
    }

    /// `setAttributes` can clear `allowsNonContiguousLayout`. Put it back so scrolling stays on the viewport.
    private static func keepViewportLayout(_ textView: NSTextView, displayViewport: Bool = false) {
        textView.layoutManager?.allowsNonContiguousLayout = true
        guard displayViewport, let manager = textView.textLayoutManager else { return }
        manager.textViewportLayoutController.layoutViewport()
    }

    /// Muted colors in the spirit of VS Code Dark Modern and Light Modern.
    private static func syntaxColor(_ kind: SyntaxTokenKind) -> NSColor {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        switch kind {
        case .comment:
            return .tertiaryLabelColor
        case .string:
            return dark
                ? NSColor(srgbRed: 0.81, green: 0.57, blue: 0.47, alpha: 1)
                : NSColor(srgbRed: 0.64, green: 0.08, blue: 0.08, alpha: 1)
        case .number:
            return dark
                ? NSColor(srgbRed: 0.71, green: 0.81, blue: 0.66, alpha: 1)
                : NSColor(srgbRed: 0.04, green: 0.53, blue: 0.35, alpha: 1)
        case .keyword:
            return dark
                ? NSColor(srgbRed: 0.34, green: 0.61, blue: 0.84, alpha: 1)
                : NSColor(srgbRed: 0.08, green: 0.16, blue: 0.65, alpha: 1)
        case .type:
            return dark
                ? NSColor(srgbRed: 0.31, green: 0.79, blue: 0.69, alpha: 1)
                : NSColor(srgbRed: 0.15, green: 0.50, blue: 0.60, alpha: 1)
        case .key:
            return dark
                ? NSColor(srgbRed: 0.61, green: 0.86, blue: 1.0, alpha: 1)
                : NSColor(srgbRed: 0.02, green: 0.32, blue: 0.65, alpha: 1)
        }
    }

    /// The characters already on screen. Does not lay out the rest of the file.
    static func visibleSpan(in textView: NSTextView) -> NSRange {
        let ns = textView.string as NSString
        guard ns.length > 0,
              let manager = textView.textLayoutManager,
              let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else {
            return NSRange(location: 0, length: min(ns.length, 4_000))
        }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let location = min(max(0, start), ns.length)
        let length = min(max(0, end - location), ns.length - location)
        return NSRange(location: location, length: length)
    }

    /// A few lines past the viewport, so a short scroll is already colored.
    private static func expanded(_ span: NSRange, in ns: NSString, pad: Int) -> NSRange {
        guard ns.length > 0, span.length > 0 else { return span }
        let lower = max(0, span.location - pad)
        let upper = min(ns.length, NSMaxRange(span) + pad)
        let startLine = ns.lineRange(for: NSRange(location: min(lower, ns.length - 1), length: 0))
        let endLine = ns.lineRange(for: NSRange(location: min(max(0, upper - 1), ns.length - 1), length: 0))
        let location = startLine.location
        let end = NSMaxRange(endLine)
        return NSRange(location: location, length: max(0, end - location))
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

    private static func styleSyntax(
        _ storage: NSTextStorage,
        style: XYZEditorStyle,
        language: SyntaxLanguage,
        within span: NSRange
    ) {
        let ns = storage.string as NSString
        guard span.length > 0, NSMaxRange(span) <= ns.length else { return }
        let range = span.location..<(span.location + span.length)
        let spans = SyntaxColoring.spans(in: storage.string, language: language, within: range)
        let keyword = style.monospaced
            ? NSFont.monospacedSystemFont(ofSize: style.fontSize, weight: .semibold)
            : proportional(size: style.fontSize, weight: .semibold)
        for item in spans {
            let colored = NSRange(location: item.location, length: item.length)
            guard colored.location >= 0, NSMaxRange(colored) <= ns.length, colored.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: syntaxColor(item.kind), range: colored)
            if item.kind == .keyword {
                storage.addAttribute(.font, value: keyword, range: colored)
            }
        }
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
