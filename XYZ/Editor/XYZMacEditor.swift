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
    // MARK: Folding

    /// Everything the indentation pass currently considers foldable.
    var foldableRanges: [CodeFolding.Fold] = []
    /// Header lines the user has folded, 1-based.
    var foldedHeaderLines: Set<Int> = []
    /// The header text of each folded block, so an edit above the block can re-anchor it
    /// instead of pointing the fold at a different declaration.
    private var foldedHeaderTexts: [Int: String] = [:]
    /// `foldedInnerRanges` is asked for every paragraph during layout; keep it ready.
    private var foldedRangesCache: [NSRange] = []
    /// Called after a fold opens or closes, so the pane can redraw its gutter.
    var onFoldingChange: (() -> Void)?
    private var foldRefreshWork: DispatchWorkItem?
    /// The ranges the TextKit 1 presentation last touched, so unfolding can repaint them.
    private var lastFoldPresentationRanges: [NSRange] = []
    /// Asks the coordinator to restyle a range. The TextKit 1 fold presentation is an
    /// attribute pass, and restyling is what puts the normal attributes back on unfold.
    var restyleRequested: ((NSRange?) -> Void)?

    /// Restored once, after the view is in a window and the inset matches the pane.
    private var pendingAnchor: EditorScrollAnchor?
    private var isAligning = false

    override var undoManager: UndoManager? {
        documentUndoManager ?? super.undoManager
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// XYZ does not do spelling or grammar. The system context menu still offers its
    /// Spelling and Grammar entries, so they are taken out of this view's menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        Self.removeSpellingItems(from: menu)
        return menu
    }

    private static func removeSpellingItems(from menu: NSMenu) {
        for item in menu.items.reversed() {
            let title = item.title.lowercased()
            if title.contains("spelling") || title.contains("grammar") {
                menu.removeItem(item)
            } else if let submenu = item.submenu {
                removeSpellingItems(from: submenu)
            }
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        unfoldFolds(intersecting: affectedCharRange)
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func changeFont(_ sender: Any?) {}

    override func changeColor(_ sender: Any?) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        selectedTextAttributes = [
            .backgroundColor: NSColor.xyzSelectionText,
            .foregroundColor: NSColor.xyzInk,
        ]
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
        if applyMarkupEdit(SourceEditing.newline(in: string, selection: sourceSelection())) {
            return
        }
        if !allowsMarkup,
           let edit = SourceEditing.autoIndent(
               in: string,
               selection: sourceSelection(),
               language: sourceLanguage
           ),
           applySourceEdit(edit) {
            return
        }
        super.insertNewline(sender)
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
        let sel = #selector(NSTextView.performFindPanelAction(_:))
        guard let superclass = XYZMacTextView.superclass(), superclass.instancesRespond(to: sel) else { return }
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
            findMarks = []
            findMarkIndex = nil
            paintFindMarks()
        }
    }

    private var findTask: Task<Void, Never>?
    private var findGeneration = 0
    private var cachedQuery: FindQuery?
    private var cachedMatches: [FindMatch] = []
    private var findMarks: [FindMatch] = []
    private var findMarkIndex: Int?
    /// Ranges painted with TextKit 2 rendering attributes. They never touch the text
    /// storage, so they cannot collide with find marks or the undo stack.
    private var readingAssistRanges: [NSTextRange] = []

    /// Drop the previous document's caret, selection, and find marks before the new text is shown.
    func clearDocumentChrome() {
        findMarks = []
        findMarkIndex = nil
        clearReadingAssists()
        resetFolding()
        setSelectedRange(NSRange(location: 0, length: 0))
        paintFindMarks()
    }

    /// Brackets at the caret and the other occurrences of the selected word. Called on
    /// every selection change; the ranges are rendering attributes only.
    func refreshReadingAssists() {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return }
        let document = content.documentRange
        let ns = string as NSString
        guard ns.length > 0 else {
            clearReadingAssists()
            return
        }
        let selection = selectedRange()
        var wanted: [(NSRange, NSColor)] = []
        if selection.length == 0 {
            if let pair = BracketMatching.pair(in: ns, caretOffset: selection.location) {
                let color = NSColor.xyzFindCurrent
                wanted.append((pair.opener, color))
                wanted.append((pair.closer, color))
            }
        }
        if let word = WordOccurrences.wordRange(in: ns, at: NSMaxRange(selection)) {
            let length = word.length
            if length >= 2, length <= 64, NSMaxRange(selection) - selection.location <= length {
                let expanded = assistWindow()
                let matches = WordOccurrences.matches(
                    of: word,
                    in: ns,
                    within: expanded,
                    limit: 400,
                    excluding: [word]
                )
                if !matches.isEmpty {
                    let color = NSColor.xyzFindMatch
                    for match in matches { wanted.append((match, color)) }
                }
            }
        }
        clearReadingAssists()
        for (range, color) in wanted {
            guard range.length > 0, NSMaxRange(range) <= ns.length else { continue }
            guard let start = content.location(document.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { continue }
            manager.setRenderingAttributes([.backgroundColor: color], for: textRange)
            readingAssistRanges.append(textRange)
        }
    }

    /// The viewport plus a few thousand characters on each side, so a short scroll keeps
    /// the word highlights.
    private func assistWindow() -> NSRange {
        let ns = string as NSString
        let visible = EditorTypography.visibleSpan(in: self)
        guard ns.length > 0, visible.length > 0 else {
            return NSRange(location: 0, length: min(ns.length, 8_000))
        }
        let lower = max(0, visible.location - 4_000)
        let upper = min(ns.length, NSMaxRange(visible) + 4_000)
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    private func clearReadingAssists() {
        guard let manager = textLayoutManager else {
            readingAssistRanges = []
            return
        }
        for range in readingAssistRanges {
            manager.setRenderingAttributes([:], for: range)
        }
        readingAssistRanges = []
    }

    /// True while match backgrounds are in the storage. Typing with no find session must
    /// not clear `.backgroundColor` over the whole note: that attribute edit alone cost
    /// more than every other part of a keystroke on a large document.
    private var hasPaintedFindMarks = false

    /// Accent marks for every match. The current one is darker. Called again after syntax styling, which clears backgrounds.
    func paintFindMarks() {
        guard let storage = textStorage else { return }
        let cap = min(findMarks.count, 2_000)
        guard cap > 0 || hasPaintedFindMarks else { return }
        let full = NSRange(location: 0, length: storage.length)
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        if full.length > 0 {
            storage.removeAttribute(.backgroundColor, range: full)
        }
        let faint = NSColor.xyzFindMatch
        let strong = NSColor.xyzFindCurrent
        if cap > 0 {
            for index in 0..<cap {
                let match = findMarks[index].range
                let range = NSRange(location: match.location, length: match.length)
                guard range.location >= 0, NSMaxRange(range) <= storage.length, range.length > 0 else { continue }
                let color = index == findMarkIndex ? strong : faint
                storage.addAttribute(.backgroundColor, value: color, range: range)
            }
        }
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        hasPaintedFindMarks = cap > 0
    }

    func singleLineSelection() -> String? {
        let selected = sourceSelection()
        guard selected.length > 0, selected.length < 2_000 else { return nil }
        let ns = string as NSString
        guard NSMaxRange(NSRange(location: selected.location, length: selected.length)) <= ns.length else { return nil }
        let text = ns.substring(with: NSRange(location: selected.location, length: selected.length))
        guard !text.contains("\n"), !text.contains("\r"), !text.isEmpty else { return nil }
        return text
    }

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
                FindScan.make(
                    text: text,
                    query: query,
                    selection: selection,
                    forward: forward,
                    stay: stayIfAlreadyThere,
                    within: model.selectionWindow
                )
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
        model.wrapped = scanned.wrapped
        findMarks = query.pattern.isEmpty ? [] : scanned.matches
        findMarkIndex = scanned.index > 0 ? scanned.index - 1 : nil
        paintFindMarks()
        guard query.pattern.isEmpty == false, let range = scanned.range else { return }
        let nsRange = NSRange(location: range.location, length: range.length)
        setSelectedRange(nsRange)
        revealFindRange(nsRange)
    }

    /// Puts the current match on screen, with a margin. A later layout pass repeats it,
    /// because TextKit 2 can put the clip back.
    func revealFindRange(_ range: NSRange) {
        unfoldFolds(intersecting: range)
        scrollFindRange(range)
        DispatchQueue.main.async { [weak self] in
            self?.scrollFindRange(range)
        }
    }

    private func scrollFindRange(_ range: NSRange) {
        guard let scroll = enclosingScrollView, let rect = findRect(range) else { return }
        let visible = scroll.contentView.bounds
        if rect.maxY + visible.height > bounds.height, let manager = textLayoutManager {
            let used = manager.usageBoundsForTextContainer
            let fitted = ceil(max(used.maxY + textContainerInset.height * 2, rect.maxY + visible.height))
            if bounds.height + 1 < fitted {
                setFrameSize(NSSize(width: bounds.width, height: fitted))
            }
        }
        let y = FindScroll.origin(
            matchMin: rect.minY,
            matchMax: rect.maxY,
            visibleOrigin: visible.origin.y,
            visibleLength: visible.height,
            contentLength: bounds.height,
            margin: 48
        )
        var x = visible.origin.x
        if rect.minX < visible.minX + 12 || rect.maxX > visible.maxX - 12 {
            let maxX = max(0, bounds.width - visible.width)
            x = min(max(0, rect.midX - visible.width / 2), maxX)
        }
        guard abs(y - visible.origin.y) > 1 || abs(x - visible.origin.x) > 1 else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        scroll.contentView.scroll(to: NSPoint(x: x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        NSAnimationContext.endGrouping()
    }

    private func findRect(_ range: NSRange) -> NSRect? {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return nil }
        let length = textStorage?.length ?? 0
        let startOffset = min(max(0, range.location), length)
        let document = content.documentRange
        let start = content.location(document.location, offsetBy: startOffset) ?? document.location
        let end = content.location(start, offsetBy: max(range.length, 1)) ?? document.endLocation
        if let layoutRange = NSTextRange(location: document.location, end: end) {
            manager.ensureLayout(for: layoutRange)
        }
        guard let fragment = manager.textLayoutFragment(for: start) else { return nil }
        var frame = fragment.layoutFragmentFrame
        let base = content.offset(from: document.location, to: fragment.rangeInElement.location)
        if let lineFragment = fragment.textLineFragments.first(where: {
            let doc = base + $0.characterRange.location
            return doc <= startOffset && startOffset < doc + max($0.characterRange.length, 1)
        }) {
            let bounds = lineFragment.typographicBounds
            frame = NSRect(
                x: frame.minX + bounds.minX,
                y: frame.minY + bounds.minY,
                width: max(bounds.width, 1),
                height: max(bounds.height, 1)
            )
        }
        let origin = textContainerOrigin
        return NSRect(x: origin.x + frame.minX, y: origin.y + frame.minY, width: max(frame.width, 1), height: max(frame.height, 1))
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
    var wrapped: Bool

    static func make(
        text: String,
        query: FindQuery,
        selection: SourceRange,
        forward: Bool,
        stay: Bool,
        within window: Range<Int>? = nil
    ) -> FindScan {
        let result = TextFind.scan(
            text: text,
            query: query,
            selection: selection,
            forward: forward,
            stay: stay,
            within: window
        )
        return FindScan(
            matches: result.matches,
            count: result.count,
            index: result.index,
            invalid: result.invalid,
            range: result.range,
            line: result.line,
            wrapped: result.wrapped
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
            return FindScan(matches: matches, count: 0, index: 0, invalid: invalid, range: nil, line: 1, wrapped: false)
        }
        let index: Int
        let wrapped: Bool
        if stay, let current = matches.firstIndex(where: {
            $0.range.location == selection.location && $0.range.length == selection.length
        }) {
            index = current
            wrapped = false
        } else if let stepped = TextFind.stepDetail(from: selection, matches: matches, forward: forward) {
            index = stepped.index
            wrapped = stepped.wrapped
        } else {
            index = 0
            wrapped = false
        }
        let range = matches[index].range
        return FindScan(
            matches: matches,
            count: matches.count,
            index: index + 1,
            invalid: invalid,
            range: range,
            line: TextFind.lineNumber(in: text, utf16: range.location),
            wrapped: wrapped
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
        alignIfReady()
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
        NSSize(width: XYZEditorStyle.sideInset(for: paneWidth), height: style.verticalInset)
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
    private var lineIndexWarm: DispatchWorkItem?

    /// Line starts for the status bar. Built off the main thread so closing find does not scan the file.
    func warmLineIndex() {
        lineIndexWarm?.cancel()
        lineIndexWarm = nil
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

    /// The text changed: the cached line starts were adjusted by `noteLineIndexEdit`
    /// for a user edit, or are kept until the rebuild below for a programmatic change.
    ///
    /// The gutter and the status bar both read this cache. Rebuilding it from the
    /// whole text on every key copied and scanned the file; the rebuild now happens
    /// once typing pauses and verifies the incremental starts.
    func lineIndexDidChange() {
        lineIndexToken += 1
        lineNumbersChanged()
        lineIndexWarm?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.warmLineIndex()
        }
        lineIndexWarm = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: item)
    }

    func cachedLineIndex() -> LineIndex? {
        lineIndexCache
    }

    /// Applies one edit to the cached line starts, so the gutter and the status bar do
    /// not rescan the file on every key. A later warm rebuild corrects anything this
    /// cannot see, such as a pasted CRLF that lands next to an existing CR.
    func noteLineIndexEdit(at location: Int, removedLength: Int, replacement: String?) {
        guard let current = lineIndexCache else { return }
        lineIndexCache = current.applyingEdit(
            at: location,
            removedLength: removedLength,
            replacement: replacement ?? ""
        )
    }

    /// The current line, already laid out. Does not ask TextKit to lay out the rest of the file.
    /// One visible layout row: the source line, its characters and its frame in text view
    /// coordinates. Works on TextKit 1 (`layoutManager`) and TextKit 2, because the live
    /// editor runs TextKit 1 while some checks render a detached TextKit 2 view.
    struct EditorTextRow {
        var line: Int
        var charRange: NSRange
        var rect: NSRect
        /// Position of one character offset inside this row, in text view coordinates.
        var position: (Int) -> NSPoint
    }

    var usesTextKit2Layout: Bool { textLayoutManager != nil }

    func visibleTextRows(in rect: NSRect) -> [EditorTextRow] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }
        let index = cachedLineIndex() ?? LineIndex(string)
        if textLayoutManager != nil {
            return textKit2Rows(in: rect, ns: ns, index: index)
        }
        return textKit1Rows(in: rect, ns: ns, index: index)
    }

    private func textKit2Rows(in rect: NSRect, ns: NSString, index: LineIndex) -> [EditorTextRow] {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return [] }
        let document = content.documentRange
        var rows: [EditorTextRow] = []
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.maxY < rect.minY { return true }
            if frame.minY > rect.maxY { return false }
            let base = content.offset(from: document.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let local = line.typographicBounds
                let character = NSRange(
                    location: base + line.characterRange.location,
                    length: line.characterRange.length
                )
                guard character.location >= 0, NSMaxRange(character) <= ns.length else { continue }
                let lineNumber = index.line(at: character.location)
                let rowRect = NSRect(
                    x: self.textContainerOrigin.x + frame.minX + local.minX,
                    y: self.textContainerOrigin.y + frame.minY + local.minY,
                    width: local.width,
                    height: local.height
                )
                let originX = self.textContainerOrigin.x
                let originY = self.textContainerOrigin.y
                rows.append(EditorTextRow(line: lineNumber, charRange: character, rect: rowRect) { [weak self] offset in
                    _ = self
                    let inside = offset - base
                    guard inside >= 0, inside < line.characterRange.length else {
                        return NSPoint(x: rowRect.minX, y: rowRect.minY)
                    }
                    let point = line.locationForCharacter(at: inside)
                    return NSPoint(
                        x: originX + frame.minX + local.minX + point.x,
                        y: originY + frame.minY + local.minY + point.y
                    )
                })
            }
            return true
        }
        return rows
    }

    private func textKit1Rows(in rect: NSRect, ns: NSString, index: LineIndex) -> [EditorTextRow] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        var rows: [EditorTextRow] = []
        let containerRect = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphRange = layout.glyphRange(forBoundingRect: containerRect, in: container)
        guard glyphRange.length > 0 else { return [] }
        let originX = textContainerOrigin.x
        let originY = textContainerOrigin.y
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, usedRect, _, lineGlyphRange, _ in
            _ = fragmentRect
            let character = layout.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            guard character.length > 0, NSMaxRange(character) <= ns.length else { return }
            let lineNumber = index.line(at: character.location)
            let rowRect = NSRect(
                x: originX + usedRect.minX,
                y: originY + usedRect.minY,
                width: usedRect.width,
                height: usedRect.height
            )
            rows.append(EditorTextRow(line: lineNumber, charRange: character, rect: rowRect) { offset in
                let clamped = min(max(offset, character.location), max(character.location, NSMaxRange(character) - 1))
                let glyph = layout.glyphIndexForCharacter(at: clamped)
                let point = layout.location(forGlyphAt: glyph)
                return NSPoint(x: originX + point.x, y: originY + point.y)
            })
        }
        // A document ending in a newline has one empty last line that TextKit reports as the
        // extra line fragment, outside the glyph range above. The caret sits there often,
        // so the band and the row list need it.
        if layout.extraLineFragmentTextContainer != nil, rows.last?.charRange.location != ns.length {
            let extra = layout.extraLineFragmentRect
            let rowRect = NSRect(
                x: originX + extra.minX,
                y: originY + extra.minY,
                width: max(extra.width, 1),
                height: max(extra.height, 1)
            )
            let character = NSRange(location: ns.length, length: 0)
            rows.append(EditorTextRow(line: index.line(at: ns.length), charRange: character, rect: rowRect) { _ in
                NSPoint(x: rowRect.minX, y: rowRect.minY)
            })
        }
        return rows
    }

    private func currentLineBand() -> NSRect? {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return nil }
        let length = textStorage?.length ?? 0
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
        NSColor.xyzEditor.setFill()
        rect.fill()
        guard isEditable else { return }
        drawCurrentLineBand(in: rect)
        drawIndentGuides(in: rect)
        drawWhitespace(in: rect)
        drawFoldMarkers(in: rect)
    }

    /// A faint ellipsis after a folded header, the only visible sign that lines are hidden
    /// there (the gutter chevron is the other).
    /// A faint ellipsis after a folded header, the only visible sign that lines are hidden
    /// there (the gutter chevron is the other).
    private func drawFoldMarkers(in rect: NSRect) {
        guard !foldedHeaderLines.isEmpty, !foldedRangesCache.isEmpty else { return }
        let ns = string as NSString
        let face = NSFont.systemFont(ofSize: max(10, style.fontSize * 0.7), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: face,
            .foregroundColor: NSColor.xyzSecondaryText,
        ]
        let label = "⋯" as NSString
        let size = label.size(withAttributes: attributes)
        let rows = visibleTextRows(in: rect)
        for fold in foldableRanges where foldedHeaderLines.contains(fold.headerLine) {
            guard let row = rows.first(where: { $0.line == fold.headerLine }) else { continue }
            let lineRange = ns.lineRange(for: NSRange(location: row.charRange.location, length: 0))
            let header = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let textFace = font ?? NSFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
            let textWidth = (header as NSString).size(withAttributes: [.font: textFace]).width
            let x = textContainerOrigin.x + textWidth + 8
            guard x + size.width < bounds.width - 2 else { continue }
            label.draw(
                at: NSPoint(x: x, y: row.rect.minY + max(0, (row.rect.height - size.height) / 2)),
                withAttributes: attributes
            )
        }
    }

    /// Middle dots for spaces and a small arrow for tabs, drawn from the laid-out line
    /// fragments so they land on the real glyph positions. Capped so a huge paste does not
    /// turn the first paint into a stipple.
    /// Middle dots for spaces and a small arrow for tabs, drawn from the laid-out rows so
    /// both layout systems place them on the real glyphs. Capped so a huge paste does not
    /// turn the first paint into a stipple.
    private func drawWhitespace(in rect: NSRect) {
        guard style.showsWhitespace else { return }
        let ns = string as NSString
        guard ns.length > 0 else { return }
        let face = font ?? NSFont.systemFont(ofSize: style.fontSize)
        let dotColor = NSColor.xyzSecondaryText.withAlphaComponent(0.4)
        dotColor.setFill()
        let arrowColor = NSColor.xyzSecondaryText.withAlphaComponent(0.55)
        var drawn = 0
        let cap = 3_000
        for row in visibleTextRows(in: rect) {
            guard drawn < cap else { break }
            var index = row.charRange.location
            let end = min(NSMaxRange(row.charRange), ns.length)
            while index < end, drawn < cap {
                let character = ns.character(at: index)
                if (character == 0x20 || character == 0x09), !isOffsetHidden(index) {
                    let point = row.position(index)
                    if character == 0x20 {
                        let dot = NSRect(
                            x: point.x + 0.5,
                            y: point.y + face.ascender * 0.35,
                            width: 1.4,
                            height: 1.4
                        )
                        NSBezierPath(ovalIn: dot).fill()
                    } else {
                        arrowColor.setStroke()
                        let arrow = NSBezierPath()
                        let y = point.y + face.ascender * 0.35
                        arrow.move(to: NSPoint(x: point.x + 1, y: y))
                        arrow.line(to: NSPoint(x: point.x + 7, y: y))
                        arrow.move(to: NSPoint(x: point.x + 5, y: y + 2))
                        arrow.line(to: NSPoint(x: point.x + 7, y: y))
                        arrow.line(to: NSPoint(x: point.x + 5, y: y - 2))
                        arrow.lineWidth = 1
                        arrow.stroke()
                        dotColor.setFill()
                    }
                    drawn += 1
                }
                index += 1
            }
        }
    }

    /// Full-width band for the caret's source line. Wrapping uses the laid-out fragment,
    /// which covers every visual row of that line. A uniform box is only for an unwrapped file.
    /// The band behind the caret's line, in text view coordinates. Nil until the line is
    /// laid out. Folding changes line geometry, so this never guesses with a uniform box
    /// unless there is no layout at all.
    func currentLineBandRect(in rect: NSRect) -> NSRect? {
        // With a real selection the selection itself shows the position; a band underneath
        // it reads as a second, taller highlight.
        guard selectedRange().length == 0 else { return nil }
        let caret = selectedRange().location
        let rows = visibleTextRows(in: rect)
        let caretLine = EditorScrollAnchor.lineNumber(at: caret, in: string)
        // The line number is the truth. A caret at a line end also ends the previous row's
        // range, so matching character ranges alone put the band one row too high.
        let lineHeight = max(1, lineBoxHeight())
        // One row can report a group's used height; a band taller than a line is never
        // right, so clamp it rather than painting a block over several lines.
        func band(for row: EditorTextRow) -> NSRect {
            NSRect(
                x: 0,
                y: row.rect.minY,
                width: bounds.width,
                height: max(1, min(row.rect.height, lineHeight * 1.4))
            )
        }
        if let row = rows.first(where: { $0.line == caretLine }) {
            return band(for: row)
        }
        if let row = rows.first(where: {
            NSLocationInRange(caret, $0.charRange)
                || (caret == NSMaxRange($0.charRange))
                || ($0.charRange.length == 0 && caret == $0.charRange.location)
        }) {
            return band(for: row)
        }
        if let last = rows.last, caret >= NSMaxRange(last.charRange) {
            var rect = band(for: last)
            rect.origin.y = last.rect.maxY
            return rect
        }
        guard useUniformBoxFallback else { return nil }
        let box = lineBoxHeight()
        let y = textContainerOrigin.y + CGFloat(max(0, caretLine - 1)) * box
        return NSRect(x: 0, y: y, width: bounds.width, height: box)
    }

    /// Before layout exists there is nothing better than the line box.
    private var useUniformBoxFallback: Bool {
        textLayoutManager == nil ? layoutManager == nil : false
    }

    private func drawCurrentLineBand(in rect: NSRect) {
        guard let band = currentLineBandRect(in: rect) else { return }
        guard band.intersects(rect) else { return }
        NSColor.xyzCurrentLine.setFill()
        band.intersection(NSRect(x: 0, y: band.minY, width: bounds.width, height: band.height)).fill()
    }

    /// A hairline at each 2-space or tab indent. Editing only, drawn from the laid-out
    /// rows, so folding and wrapping both keep the guides on their own line.
    private func drawIndentGuides(in rect: NSRect) {
        let ns = string as NSString
        guard ns.length > 0 else { return }
        let face = font ?? EditorTypography.baseFont(style)
        let originX = textContainerOrigin.x
        if effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            NSColor.xyzSecondaryText.withAlphaComponent(0.45).setStroke()
        } else {
            NSColor.xyzDivider.setStroke()
        }
        let path = NSBezierPath()
        for row in visibleTextRows(in: rect) {
            if isLineHidden(row.line) { continue }
            let lineRange = ns.lineRange(for: NSRange(location: row.charRange.location, length: 0))
            let lineText = ns.substring(with: lineRange)
            let levels = Self.indentLevels(lineText)
            guard levels > 0 else { continue }
            let rowFont = textStorage?.attribute(.font, at: lineRange.location, effectiveRange: nil) as? NSFont ?? face
            let step = ("  " as NSString).size(withAttributes: [.font: rowFont]).width
            for level in 1...levels {
                let x = originX + CGFloat(level) * step
                path.move(to: NSPoint(x: x, y: row.rect.minY))
                path.line(to: NSPoint(x: x, y: row.rect.maxY))
            }
        }
        path.lineWidth = 1
        path.stroke()
    }

    private func lineBoxHeight() -> CGFloat {
        let face = font ?? NSFont.systemFont(ofSize: style.fontSize)
        return max(1, EditorTypography.paragraphStyle(style, font: face).minimumLineHeight)
    }

    /// Two spaces, or one tab, are one indent.
    static func indentLevels(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 2 - columns % 2
            } else {
                break
            }
        }
        return columns / 2
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
        guard let index = lineIndexCache else { return nil }
        if let manager = textLayoutManager,
           let content = manager.textContentManager,
           let location = manager.textViewportLayoutController.viewportRange?.location {
            let offset = content.offset(from: content.documentRange.location, to: location)
            return max(1, index.line(at: max(0, offset)))
        }
        // The live editor is TextKit 1, which has no viewport controller; ask the layout
        // manager for the character at the top of the visible rect instead.
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let visible = visibleRect
        guard visible.height > 1 else { return nil }
        let point = NSPoint(
            x: max(0, visible.minX - textContainerOrigin.x),
            y: max(0, visible.minY - textContainerOrigin.y)
        )
        let offset = layout.characterIndex(
            for: point,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
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
        textView.onFoldingChange = { [weak self] in
            self?.gutter.invalidateLines()
            self?.needsLayout = true
        }
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
                self?.gutter.noteGeometryChanged()
            }
        }
        needsLayout = true
    }

    func noteTextLayout() {
        // Display only. Marking the pane dirty from the text view's layout never finishes.
        gutter.noteGeometryChanged()
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
        let gutterFrame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let scrollFrame = NSRect(x: width, y: 0, width: max(1, bounds.width - width), height: bounds.height)
        let frameChanged = gutter.frame != gutterFrame || scrollView.frame != scrollFrame
        if gutter.frame != gutterFrame { gutter.frame = gutterFrame }
        if scrollView.frame != scrollFrame { scrollView.frame = scrollFrame }
        if frameChanged {
            gutter.noteGeometryChanged()
        }
    }

    /// The hosting view includes the status bar. Keep this pane above that bar.
    private func clampAboveStatusBar() {
        guard let content = window?.contentView, let parent = superview else { return }
        guard let bar = Self.statusBar(in: content) else { return }
        let barBox = bar.convert(bar.bounds, to: content)
        guard barBox.height > 8, barBox.height < 48 else { return }
        var mine = convert(bounds, to: content)
        if content.isFlipped {
            let overlap = mine.maxY - barBox.minY
            guard overlap > 0.5, mine.height - overlap > 1 else { return }
            mine.size.height -= overlap
        } else {
            let overlap = barBox.maxY - mine.minY
            guard overlap > 0.5, mine.height - overlap > 1 else { return }
            mine.origin.y += overlap
            mine.size.height -= overlap
        }
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
    var syntax: SyntaxLanguage
    var lineNumbers: Bool
    var find: EditorFindModel?
    var onSelection: ((EditorCaret) -> Void)?
    var onTextChange: (String) -> Void

    func makeNSView(context: Context) -> EditorPane {
        let textView = XYZMacTextView(usingTextLayoutManager: true)
        textView.enableFolding()
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
        // XYZ does not spell check: the app is for notes and code, not prose review.
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
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
        textView.restyleRequested = { [weak coordinator = context.coordinator] range in
            coordinator?.restyle(edited: range)
        }
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
        textView.insertionPointColor = isEditable ? .xyzInk : .clear
        if editingChanged {
            textView.showViewport()
            if !isEditable {
                context.coordinator.forgetViewportLine()
            }
        }
        let markupChanged = textView.allowsMarkup != markup
        textView.allowsMarkup = markup
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
        textView.restyleRequested = { [weak coordinator = context.coordinator] range in
            coordinator?.restyle(edited: range)
        }
        textView.refreshFolding(immediate: true)
        find?.language = syntax
        let hadEditor = find?.editorView != nil
        find?.editorView = textView
        if !hadEditor, find?.visible == true, find?.surface == .editor {
            find?.scheduleRefresh()
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
            } else {
                textView.clearDocumentChrome()
                if markupChanged || syntaxChanged {
                    context.coordinator.restyle(edited: nil)
                }
            }
        } else if markupChanged || syntaxChanged {
            context.coordinator.restyle(edited: nil)
        }
        if let anchor = scrollLink.take(for: .source) {
            textView.reveal(anchor)
            if anchor.line > 1 {
                scrollLink.onViewportLine?(anchor.line)
            }
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
        let paragraph = EditorTypography.paragraphStyle(style, font: font)
        textView.backgroundColor = .xyzEditor
        textView.textColor = .xyzInk
        textView.insertionPointColor = .xyzInk
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.xyzInk,
            .paragraphStyle: paragraph,
        ]
        scrollView.backgroundColor = .xyzEditor
        scrollView.clipsToBounds = true
        scrollView.contentView.clipsToBounds = true
        scrollView.contentView.drawsBackground = false
        textView.insertionPointColor = textView.isEditable ? .xyzInk : .clear
        applySelectionChrome(textView)
    }

    private func applySelectionChrome(_ textView: XYZMacTextView) {
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.xyzSelectionText,
            .foregroundColor: NSColor.xyzInk,
        ]
    }

    /// Wrap tracks the pane. With wrap off, the line keeps its length and the pane scrolls sideways.
    private func applyWrap(textView: XYZMacTextView, scrollView: NSScrollView, wraps: Bool) {
        textView.textContainer?.widthTracksTextView = wraps
        textView.isHorizontallyResizable = !wraps
        scrollView.hasHorizontalScroller = !wraps
        scrollView.horizontalScrollElasticity = .none
        if wraps {
            textView.autoresizingMask = [.width]
            let width = max(scrollView.contentView.bounds.width, scrollView.bounds.width, 1)
            textView.setFrameSize(NSSize(width: width, height: max(textView.bounds.height, 1)))
            textView.textContainer?.containerSize = NSSize(width: max(1, width - 1), height: CGFloat.greatestFiniteMagnitude)
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

        /// The line at the top of the page, in Reading and while Editing is scrolled.
        func publishViewportLine() {
            guard let textView, let scrollLink else { return }
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
                // One text view serves every tab in a folder window, and the undo stack
                // belongs to that view. A range from the previous file would raise
                // NSRangeException or silently edit this one, so a whole-content
                // replacement starts a new history. The same holds when a document
                // scene reloads the file from disk.
                if textView.string != replacement {
                    textView.undoManager?.removeAllActions()
                }
                textView.undoManager?.disableUndoRegistration()
                textView.string = replacement
                textView.clearDocumentChrome()
                textView.refreshFolding(immediate: true)
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
            (textView as? XYZMacTextView)?.noteLineIndexEdit(
                at: affectedCharRange.location,
                removedLength: affectedCharRange.length,
                replacement: replacementString
            )
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? XYZMacTextView else { return }
            textView.unfoldSelectionIfNeeded()
            textView.caretMoved()
            textView.refreshReadingAssists()
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
            (notification.object as? XYZMacTextView)?.noteFoldingTextChanged()
            guard let textView = notification.object as? NSTextView else { return }
            (textView as? XYZMacTextView)?.lineIndexDidChange()
            // Marked Chinese (and other IME) text is still being composed. Restyling it drops the composition.
            if !textView.hasMarkedText() {
                let length = textView.textStorage?.length ?? 0
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
            textView.applyFoldPresentationForTextKit1()
            textView.lineNumbersChanged()
        }
    }
}

enum EditorTypography {
    static let stylingLimit = 250_000
    /// Below this many UTF-16 units, each keystroke restyles the whole note. Above it,
    /// only the lines around the edit are restyled now and the whole note after the
    /// typing pauses (`textDidChange` schedules that). A 4,000-character note is a
    /// couple of screens; a 100 KB chapter is not.
    static let immediateLimit = 4_000

    static func baseFont(_ style: XYZEditorStyle) -> NSFont {
        face(style, size: style.fontSize, weight: .regular)
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
        return face(style, size: size, weight: .semibold)
    }

    static func markerFont(_ style: XYZEditorStyle) -> NSFont {
        let size = max(12, (style.fontSize * 0.86).rounded())
        return face(style, size: size, weight: .regular)
    }

    static func codeFont(_ style: XYZEditorStyle, inline: Bool = true) -> NSFont {
        var code = style
        code.monospaced = true
        // Only inline code is optically smaller. A fenced block is a full editor row.
        let size = inline ? (style.fontSize * 0.92).rounded() : style.fontSize
        return face(code, size: size, weight: .regular)
    }

    static func naturalLineHeight(_ font: NSFont) -> CGFloat {
        let latin = font.ascender - font.descender + font.leading
        // Reserve room for the chosen CJK fallback even on Latin-only rows. At tight
        // line spacing, inserting one Chinese character must not change the row rhythm.
        let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] ?? []
        let cjk = cascade.first.flatMap { NSFont(descriptor: $0, size: font.pointSize) }
        return max(latin, cjk.map { $0.ascender - $0.descender + $0.leading } ?? latin)
    }

    static func paragraphStyle(_ style: XYZEditorStyle, font: NSFont) -> NSMutableParagraphStyle {
        style.paragraphStyle(
            naturalLineHeight: naturalLineHeight(font),
            spaceAdvance: (" " as NSString).size(withAttributes: [.font: font]).width
        )
    }

    /// The same face owns Latin and CJK glyphs; no manually assembled cascade.
    static func face(_ style: XYZEditorStyle, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        AppFonts.register()
        let name = AppFonts.name(monospaced: style.monospaced, emphasized: weight >= .medium)
        return NSFont(name: name, size: size)
            ?? (style.monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                                : NSFont.systemFont(ofSize: size, weight: weight))
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
        let paragraph = paragraphStyle(style, font: font)
        // `mutableString` is a view on the storage; `storage.string` copies the file.
        let ns = storage.mutableString as NSString
        let full = NSRange(location: 0, length: ns.length)
        let span: NSRange
        if full.length > immediateLimit {
            // Only the edited lines need the base attributes again. A large pad around
            // them made every keystroke rewrite thousands of characters of attributes.
            span = lineSpan(ns, around: edited ?? visibleSpan(in: textView))
        } else {
            span = full
        }
        textView.undoManager?.disableUndoRegistration()
        storage.beginEditing()
        if span.length > 0, span.location >= 0, NSMaxRange(span) <= ns.length {
            storage.setAttributes([
                .font: font,
                .foregroundColor: NSColor.xyzInk,
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
            .foregroundColor: NSColor.xyzInk,
            .paragraphStyle: paragraph,
        ]
        if let editor = textView as? XYZMacTextView {
            editor.paintFindMarks()
        }
        keepViewportLayout(textView)
    }

    /// The size change itself. Colors and heading sizes are a later pass.
    /// Laying out `documentRange` here turns viewport layout off for good, so later typing lays out the whole note.
    static func applyMetrics(to textView: NSTextView, style: XYZEditorStyle) {
        guard let storage = textView.textStorage else { return }
        let font = baseFont(style)
        let paragraph = paragraphStyle(style, font: font)
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
            .foregroundColor: NSColor.xyzInk,
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

    /// The colour for one token kind, used by both the plain code path and fenced blocks.
    private static func tokenColor(_ kind: SyntaxTokenKind) -> NSColor? {
        syntaxColor(kind)
    }

    /// The active theme's color for one token kind.
    private static func syntaxColor(_ kind: SyntaxTokenKind) -> NSColor {
        NSColor.xyzSyntax(kind)
    }

    /// The characters already on screen. Does not lay out the rest of the file.
    static func visibleSpan(in textView: NSTextView) -> NSRange {
        let textLength = textView.textStorage?.length ?? 0
        guard textLength > 0,
              let manager = textView.textLayoutManager,
              let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange else {
            return NSRange(location: 0, length: min(textLength, 4_000))
        }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let location = min(max(0, start), textLength)
        let visibleLength = min(max(0, end - location), textLength - location)
        return NSRange(location: location, length: visibleLength)
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
        // Syntax changes color, never the selected face, weight or glyph advances.
        for item in spans {
            let colored = NSRange(location: item.location, length: item.length)
            guard colored.location >= 0, NSMaxRange(colored) <= ns.length, colored.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: syntaxColor(item.kind), range: colored)
        }
    }

    private static func styleMarkup(_ storage: NSTextStorage, style: XYZEditorStyle, within span: NSRange) {
        let ns = storage.string as NSString
        let syntax = NSColor.xyzTertiaryText
        let limit = min(NSMaxRange(span), ns.length)
        var location = max(0, span.location)
        // Typing inside a fenced block restyles the whole block: token state (comments,
        // multi-line strings) is only right when the block is scanned as one text.
        if fenceIsOpen(ns, before: location), let open = precedingFenceLine(ns, before: location) {
            location = open.location
        }
        while location < limit {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = contentRange(ns, lineRange)
            if content.range.length > 0, let info = fenceInfo(content.text) {
                let block = fenceBlock(ns: ns, openingLine: lineRange, info: info)
                styleFenceBlock(ns: ns, block: block, storage: storage, style: style, fenceColor: syntax)
                let next = max(NSMaxRange(block.body), NSMaxRange(lineRange))
                if next <= location { break }
                location = next
                continue
            }
            if content.range.length > 0 {
                styleLine(
                    ns: ns,
                    content: content.text,
                    range: content.range,
                    storage: storage,
                    style: style,
                    syntax: syntax
                )
            }
            let next = NSMaxRange(lineRange)
            if next <= location || next >= limit { break }
            location = next
        }
    }

    private struct FenceBlock {
        var openingLine: NSRange
        var body: NSRange
        var closingLine: NSRange?
        var language: SyntaxLanguage
    }

    /// The text after the fence marker, such as `swift` in ```` ```swift ````.
    private static func fenceInfo(_ content: String) -> String? {
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
        guard indent <= 3, index < ns.length else { return nil }
        let marker = ns.character(at: index)
        guard marker == 0x60 || marker == 0x7E else { return nil }
        var count = 0
        while index < ns.length, ns.character(at: index) == marker {
            count += 1
            index += 1
        }
        guard count >= 3 else { return nil }
        return (content as NSString).substring(from: index)
    }

    /// The fence line that opens the block around `location`; the nearest fence line above
    /// it, because the caller already knows the location is inside one.
    private static func precedingFenceLine(_ ns: NSString, before location: Int) -> NSRange? {
        var cursor = 0
        var last: NSRange?
        while cursor < location, cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let content = contentRange(ns, line)
            if isFence(content.text) { last = line }
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
        }
        return last
    }

    private static func fenceBlock(ns: NSString, openingLine: NSRange, info: String) -> FenceBlock {
        let language = FileFormats.fenceLanguage(info)
        var cursor = NSMaxRange(openingLine)
        var closing: NSRange?
        while cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            if isFence(contentRange(ns, line).text) {
                closing = line
                break
            }
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
        }
        let bodyEnd = closing?.location ?? min(ns.length, NSMaxRange(openingLine))
        let body = NSRange(location: NSMaxRange(openingLine), length: max(0, bodyEnd - NSMaxRange(openingLine)))
        return FenceBlock(openingLine: openingLine, body: body, closingLine: closing, language: language)
    }

    private static func styleFenceBlock(
        ns: NSString,
        block: FenceBlock,
        storage: NSTextStorage,
        style: XYZEditorStyle,
        fenceColor: NSColor
    ) {
        let codeFace = codeFont(style, inline: false)
        var codeStyle = style
        codeStyle.lineHeight = XYZEditorStyle.codeLineHeight(forProse: style.lineHeight)
        let paragraph = paragraphStyle(codeStyle, font: codeFace)
        let lineRanges = [block.openingLine, block.closingLine].compactMap { $0 }
        for line in lineRanges {
            let content = contentRange(ns, line)
            guard content.range.length > 0, NSMaxRange(content.range) <= storage.length else { continue }
            storage.addAttribute(.font, value: codeFace, range: content.range)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: line)
            storage.addAttribute(.foregroundColor, value: fenceColor, range: content.range)
        }
        guard block.body.length > 0, NSMaxRange(block.body) <= storage.length else { return }
        storage.addAttribute(.font, value: codeFace, range: block.body)
        storage.addAttribute(.paragraphStyle, value: paragraph, range: block.body)
        guard block.language != .plain else { return }
        let bodyText = ns.substring(with: block.body)
        for span in SyntaxColoring.spans(in: bodyText, language: block.language) {
            let range = NSRange(location: block.body.location + span.location, length: span.length)
            guard range.location >= 0, NSMaxRange(range) <= storage.length else { continue }
            guard let color = tokenColor(span.kind) else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: range)
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
        syntax: NSColor
    ) {
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
// MARK: - Folding

/// TextKit 2 has no API for hiding a range, but its content storage asks for the
/// paragraphs it should lay out. A folded block is answered with a paragraph of the same
/// length whose characters are zero-width, and a zero line height, so it collapses to the
/// header's own line while the text, the offsets, the undo stack and saving stay untouched.
extension XYZMacTextView: NSTextContentStorageDelegate {
    func enableFolding() {
        if let storage = textLayoutManager?.textContentManager as? NSTextContentStorage {
            storage.delegate = self
        }
    }

    /// TextKit 1 has no content-storage hook. A folded block is collapsed with a display
    /// attribute pass: a 0.1 pt face, a zero line height and clear ink keep every offset,
    /// the undo stack and the saved text untouched.
    func applyFoldPresentationForTextKit1() {
        guard !usesTextKit2Layout, let storage = textStorage else { return }
        let previous = lastFoldPresentationRanges
        let current = foldedRangesCache
        lastFoldPresentationRanges = current
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        for range in current where range.length > 0 && NSMaxRange(range) <= storage.length {
            let face = NSFont(descriptor: (font ?? NSFont.systemFont(ofSize: style.fontSize)).fontDescriptor, size: 0.1)
                ?? NSFont.systemFont(ofSize: 0.1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 0
            paragraph.maximumLineHeight = 0
            paragraph.lineSpacing = 0
            storage.addAttributes(
                [.font: face, .paragraphStyle: paragraph, .foregroundColor: NSColor.clear],
                range: range
            )
        }
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        if let layout = layoutManager {
            var merged: [NSRange] = []
            for range in previous + current where NSMaxRange(range) <= storage.length && range.length > 0 {
                if let last = merged.last, NSMaxRange(last) >= range.location {
                    merged[merged.count - 1] = NSUnionRange(last, range)
                } else {
                    merged.append(range)
                }
            }
            for range in merged {
                layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                layout.invalidateDisplay(forCharacterRange: range)
            }
        }
        needsDisplay = true
    }

    func refreshFolding(immediate: Bool) {
        foldRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuildFoldableRanges()
        }
        foldRefreshWork = work
        if immediate {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func noteFoldingTextChanged() {
        refreshFolding(immediate: false)
    }

    /// Drops every fold and its layout state. A new document starts whole.
    func resetFolding() {
        foldRefreshWork?.cancel()
        let before = foldedInnerRanges
        foldableRanges = []
        foldedHeaderLines = []
        foldedHeaderTexts = [:]
        rebuildFoldedRangesCache()
        invalidateFoldLayout(in: before)
        onFoldingChange?()
    }

    private func rebuildFoldableRanges() {
        // A file past the syntax limit does not get an indentation pass on every pause.
        guard (string as NSString).length <= 400_000 else {
            resetFolding()
            return
        }
        let before = foldedInnerRanges
        let previous = foldedHeaderTexts
        let next = CodeFolding.folds(in: string, language: sourceLanguage)
        foldableRanges = next
        // Re-anchor each folded block by its header text. An edit above the block moves
        // the line number; the block stays folded where the same declaration now is.
        var anchored: Set<Int> = []
        var texts: [Int: String] = [:]
        for (_, text) in previous {
            guard let match = next.first(where: { headerText(atLine: $0.headerLine) == text }) else { continue }
            if anchored.insert(match.headerLine).inserted {
                texts[match.headerLine] = text
            }
        }
        foldedHeaderLines = anchored
        foldedHeaderTexts = texts
        rebuildFoldedRangesCache()
        let after = foldedInnerRanges
        invalidateFoldLayout(in: before + after)
        onFoldingChange?()
    }

    var hasFoldableLines: Bool { !foldableRanges.isEmpty }

    /// True for a line that is collapsed inside a folded header. Its number, indent guides
    /// and whitespace marks are not drawn.
    func isLineHidden(_ line: Int) -> Bool {
        guard !foldedHeaderLines.isEmpty else { return false }
        return foldableRanges.contains { fold in
            foldedHeaderLines.contains(fold.headerLine) && line > fold.headerLine && line <= fold.lastLine
        }
    }

    func isOffsetHidden(_ offset: Int) -> Bool {
        guard !foldedHeaderLines.isEmpty else { return false }
        return foldedRangesCache.contains { NSLocationInRange(offset, $0) }
    }

    /// Header line → folded, for the gutter.
    func foldHeaderState() -> [Int: Bool] {
        var state: [Int: Bool] = [:]
        for fold in foldableRanges {
            state[fold.headerLine] = foldedHeaderLines.contains(fold.headerLine)
        }
        return state
    }

    var foldedInnerRanges: [NSRange] { foldedRangesCache }

    private func rebuildFoldedRangesCache() {
        foldedRangesCache = foldableRanges
            .filter { foldedHeaderLines.contains($0.headerLine) }
            .map(\.innerRange)
    }

    private func headerText(atLine line: Int) -> String? {
        guard let index = cachedLineIndex(), line >= 1, line <= index.count else { return nil }
        let ns = string as NSString
        let start = index.starts[line - 1]
        let end = line < index.count ? index.starts[line] : ns.length
        guard end >= start, end <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fold(atLine line: Int) -> CodeFolding.Fold? {
        foldableRanges.first { $0.headerLine == line }
    }

    /// The fold whose header is the nearest one at or above `line`, for "fold at caret".
    func enclosingFold(atLine line: Int) -> CodeFolding.Fold? {
        foldableRanges.last { $0.headerLine <= line }
    }

    func toggleFold(atLine line: Int) {
        guard let fold = fold(atLine: line) else { return }
        let before = foldedInnerRanges
        if foldedHeaderLines.contains(line) {
            foldedHeaderLines.remove(line)
            foldedHeaderTexts[line] = nil
        } else {
            foldedHeaderLines.insert(line)
            if let text = headerText(atLine: line) { foldedHeaderTexts[line] = text }
        }
        rebuildFoldedRangesCache()
        invalidateFoldLayout(in: before + foldedInnerRanges)
        onFoldingChange?()
        needsDisplay = true
        lineNumberGutter?.needsDisplay = true
    }

    func foldAll() {
        let before = foldedInnerRanges
        foldedHeaderLines = Set(foldableRanges.map(\.headerLine))
        foldedHeaderTexts = [:]
        for line in foldedHeaderLines {
            if let text = headerText(atLine: line) { foldedHeaderTexts[line] = text }
        }
        rebuildFoldedRangesCache()
        invalidateFoldLayout(in: before + foldedInnerRanges)
        onFoldingChange?()
        needsDisplay = true
        lineNumberGutter?.needsDisplay = true
    }

    func unfoldAll() {
        let before = foldedInnerRanges
        foldedHeaderLines = []
        foldedHeaderTexts = [:]
        rebuildFoldedRangesCache()
        invalidateFoldLayout(in: before)
        onFoldingChange?()
        needsDisplay = true
        lineNumberGutter?.needsDisplay = true
    }

    /// Opens any fold that hides a character range, so typing, pasting and find can show
    /// what they touch.
    func unfoldFolds(intersecting range: NSRange) {
        guard !foldedHeaderLines.isEmpty, range.length >= 0 else { return }
        let touched = foldableRanges.filter { fold in
            foldedHeaderLines.contains(fold.headerLine)
                && NSIntersectionRange(fold.innerRange, range).length > 0
        }
        guard !touched.isEmpty else { return }
        let before = foldedInnerRanges
        for fold in touched {
            foldedHeaderLines.remove(fold.headerLine)
            foldedHeaderTexts[fold.headerLine] = nil
        }
        rebuildFoldedRangesCache()
        invalidateFoldLayout(in: before + foldedInnerRanges)
        onFoldingChange?()
        lineNumberGutter?.needsDisplay = true
    }

    /// Arrow keys move the caret into the hidden line before the selection callback runs;
    /// opening the fold there keeps typing possible everywhere.
    func unfoldSelectionIfNeeded() {
        guard !foldedHeaderLines.isEmpty else { return }
        let selection = selectedRange()
        unfoldFolds(intersecting: NSRange(location: selection.location, length: max(1, selection.length)))
    }

    @objc func xyzToggleFold(_ sender: Any?) {
        guard let line = caretLineNumber() else { return }
        if let fold = enclosingFold(atLine: line) {
            toggleFold(atLine: fold.headerLine)
        }
    }

    @objc func xyzFoldAll(_ sender: Any?) { foldAll() }

    @objc func xyzUnfoldAll(_ sender: Any?) { unfoldAll() }

    private func caretLineNumber() -> Int? {
        guard let index = cachedLineIndex() else {
            return nil
        }
        return index.line(at: min(max(0, selectedRange().location), (string as NSString).length))
    }

    /// Folding changes no characters, but the layout has to be told that these paragraphs
    /// need to be built again. Marking the attributes edited in the backing store is what
    /// makes the content storage ask the delegate again.
    private func invalidateFoldLayout(in ranges: [NSRange]) {
        if !usesTextKit2Layout {
            // TextKit 1: restyling the touched lines clears the old presentation, and the
            // restyle path reapplies it for the folds that remain.
            guard let storage = textStorage else { return }
            let ns = storage.string as NSString
            var merged: [NSRange] = []
            for range in ranges where range.length > 0 {
                let start = min(max(0, range.location), ns.length)
                let end = min(max(start, NSMaxRange(range)), ns.length)
                let expanded = ns.lineRange(for: NSRange(location: start, length: end - start))
                if let last = merged.last, NSMaxRange(last) >= expanded.location {
                    merged[merged.count - 1] = NSUnionRange(last, expanded)
                } else {
                    merged.append(expanded)
                }
            }
            if let restyleRequested {
                for range in merged { restyleRequested(range) }
            } else {
                applyFoldPresentationForTextKit1()
            }
            needsDisplay = true
            return
        }
        guard let storage = textStorage else { return }
        let length = storage.length
        var merged: [NSRange] = []
        for range in ranges where NSMaxRange(range) <= length && range.length > 0 {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        guard !merged.isEmpty else { return }
        undoManager?.disableUndoRegistration()
        for range in merged {
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
        }
        undoManager?.enableUndoRegistration()
        if let manager = textLayoutManager, let content = manager.textContentManager {
            manager.invalidateLayout(for: content.documentRange)
            manager.textViewportLayoutController.layoutViewport()
        }
        needsLayout = true
    }

    // MARK: TextKit 2 content storage

    public func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard !foldedHeaderLines.isEmpty,
              let storage = textStorage,
              NSMaxRange(range) <= storage.length,
              foldedInnerRanges.contains(where: { NSIntersectionRange($0, range).length > 0 })
        else { return nil }
        let source = storage.attributedSubstring(from: range)
        // The delegate contract requires the same length. Zero-width spaces keep every
        // offset identical; newlines stay because they belong to the next paragraph.
        let hidden = NSMutableAttributedString(string: String(repeating: "\u{200B}", count: range.length))
        let ns = source.string as NSString
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 0x0A {
                hidden.replaceCharacters(in: NSRange(location: index, length: 1), with: "\n")
            }
            index += 1
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 0
        paragraph.maximumLineHeight = 0
        paragraph.lineSpacing = 0
        hidden.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
                .paragraphStyle: paragraph,
            ],
            range: NSRange(location: 0, length: hidden.length)
        )
        return NSTextParagraph(attributedString: hidden)
    }
}

#endif
