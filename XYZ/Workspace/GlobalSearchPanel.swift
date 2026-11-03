#if os(macOS)
import AppKit
import XYZCore

/// ⌘K. A centered search panel: recent files, filename matches, and text matches.
@MainActor
final class GlobalSearchController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private var panel: SearchPanel?
    private var search: NSSearchField?
    private var table: NSTableView?
    private var empty: NSTextField?
    private var chips: [NSButton] = []
    private weak var session: WorkspaceSession?
    private var rows: [Row] = []
    private var fileHits: [GlobalFileHit] = []
    private var fileMore = 0
    private var contentHits: [WorkspaceContentHit] = []
    private var contentMore = 0
    private var contentCapped = false
    private var scope: Scope = .all
    private var generation = 0
    private var task: Task<Void, Never>?
    /// What the field editor currently holds. The search task reads this and never writes it back.
    private var typedQuery = ""
    private var suppressResign = false
    private var closing = false

    enum Scope: Int {
        case all = 0
        case files = 1
        case content = 2
    }

    var isOpen: Bool { panel?.isVisible == true }

    func owns(_ window: NSWindow?) -> Bool {
        window != nil && window === panel
    }

    func closeIfOpen() -> Bool {
        guard isOpen else { return false }
        close()
        return true
    }

    func toggle(session: WorkspaceSession) {
        if isOpen {
            close()
        } else {
            show(session: session)
        }
    }

    func show(session: WorkspaceSession) {
        self.session = session
        let panel = self.panel ?? makePanel()
        self.panel = panel
        scope = .all
        updateChips()
        typedQuery = ""
        search?.stringValue = ""
        showRecents()
        place(panel)
        suppressResign = true
        panel.makeKeyAndOrderFront(nil)
        if let search {
            panel.makeFirstResponder(search)
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { () -> Void in
                self?.suppressResign = false
                WorkspaceWindowController.closeStrayWindows()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !suppressResign else { return }
        close()
    }

    func controlTextDidChange(_ notification: Notification) {
        // `stringValue` during this callback is one character behind and writing it back drops that character.
        if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
            typedQuery = editor.string
        } else if let editor = search?.currentEditor() as? NSTextView {
            typedQuery = editor.string
        }
        schedule()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveDownAndModifySelection(_:)) {
            move(1)
            return true
        }
        if selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveUpAndModifySelection(_:)) {
            move(-1)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            openSelection(closePanel: !flags.contains(.command))
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        if selector == #selector(NSResponder.insertTab(_:)) {
            cycleScope(1)
            return true
        }
        if selector == #selector(NSResponder.insertBacktab(_:)) {
            cycleScope(-1)
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 28 }
        switch rows[row] {
        case .header: return 22
        case .more: return 24
        case .content: return 40
        case .recent, .file: return 32
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].selectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title):
            let cell = reusedText(tableView, id: "header")
            cell.apply(title: headerText(title), detail: nil, icon: nil)
            return cell
        case .more(let title):
            let cell = reusedText(tableView, id: "more")
            cell.apply(title: quiet(title), detail: nil, icon: nil)
            return cell
        case .recent(let path):
            let cell = reusedText(tableView, id: "recent")
            cell.apply(title: nameText(path), detail: parentText(path), icon: icon(for: path))
            return cell
        case .file(let hit):
            let cell = reusedText(tableView, id: "file")
            cell.apply(
                title: emphasized(hit.name, indices: hit.nameIndices, size: 13),
                detail: pathDetail(hit),
                icon: icon(for: hit.relativePath)
            )
            return cell
        case .content(let hit):
            let cell = reusedText(tableView, id: "content")
            let name = (hit.relativePath as NSString).lastPathComponent
            let line = String(format: String(localized: "Ln %lld"), Int64(hit.lineNumber))
            cell.apply(
                title: plain("\(name)  \(line)", size: 13),
                detail: snippet(hit.excerpt, query: typedQuery),
                icon: icon(for: hit.relativePath)
            )
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: SearchRowView.identifier, owner: self) as? SearchRowView ?? SearchRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    @objc private func openClicked(_ sender: Any?) {
        openSelection(closePanel: true)
    }

    @objc private func chipClicked(_ sender: NSButton) {
        scope = Scope(rawValue: sender.tag) ?? .all
        updateChips()
        rebuild()
    }

    fileprivate func setScope(_ scope: Scope) {
        self.scope = scope
        updateChips()
        rebuild()
    }

    private func makePanel() -> SearchPanel {
        let panel = SearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.controller = self
        panel.delegate = self
        panel.title = String(localized: "Find in Files")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.isRestorable = false

        let search = QueryField()
        search.placeholderString = String(localized: "Search files and text")
        search.delegate = self
        search.controlSize = .large
        search.font = .systemFont(ofSize: 16)
        search.focusRingType = .none
        search.translatesAutoresizingMaskIntoConstraints = false
        search.setAccessibilityLabel(String(localized: "Find in Files"))
        self.search = search

        let chipRow = NSStackView()
        chipRow.orientation = .horizontal
        chipRow.spacing = 6
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        let titles = [
            String(localized: "All"),
            String(localized: "Files"),
            String(localized: "Content"),
        ]
        chips = titles.enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(chipClicked(_:)))
            button.tag = index
            button.bezelStyle = .recessed
            button.setButtonType(.pushOnPushOff)
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            chipRow.addArrangedSubview(button)
            return button
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chipRow.addArrangedSubview(spacer)

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.rowHeight = 32
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.target = self
        table.action = #selector(openClicked(_:))
        self.table = table

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let empty = NSTextField(labelWithString: String(localized: "No matches"))
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        self.empty = empty

        let stack = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addSubview(search)
        stack.addSubview(chipRow)
        stack.addSubview(scroll)
        stack.addSubview(empty)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: stack.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            chipRow.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            chipRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            chipRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        updateChips()
        return panel
    }

    private func schedule() {
        task?.cancel()
        let query = typedQuery
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session else {
            showRecents()
            return
        }
        generation += 1
        let token = generation
        let entries = session.indexedEntries
        let showsHidden = session.showsHiddenFiles
        task = Task { [weak self, weak session] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            // A newer keystroke cancels this task. Do not read or write the field from here.
            let latest = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latest.isEmpty else {
                self.showRecents()
                return
            }
            let files = await Task.detached(priority: .userInitiated) {
                GlobalFileSearch.match(entries: entries, query: latest, showsHidden: showsHidden)
            }.value
            let content = await session?.searchPanelContents(query: latest) ?? (hits: [], more: 0, capped: false)
            guard !Task.isCancelled, self.generation == token else { return }
            self.fileHits = files.hits
            self.fileMore = files.more
            self.contentHits = content.hits
            self.contentMore = content.more
            self.contentCapped = content.capped
            self.rebuild()
        }
    }

    /// The field editor is the query. A table reload must not put an older string back.
    private func restoreField() {
        guard let editor = search?.currentEditor() as? NSTextView else { return }
        guard editor.string != typedQuery else { return }
        editor.string = typedQuery
        let end = (typedQuery as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
    }

    private func showRecents() {
        task?.cancel()
        generation += 1
        fileHits = []
        fileMore = 0
        contentHits = []
        contentMore = 0
        contentCapped = false
        let paths = session?.recentOpenPaths() ?? []
        var next: [Row] = []
        if !paths.isEmpty {
            next.append(.header(String(localized: "Recent")))
            next.append(contentsOf: paths.prefix(12).map { .recent($0) })
        }
        rows = next
        applyRows()
    }

    private func rebuild() {
        var next: [Row] = []
        if scope != .content, !fileHits.isEmpty {
            next.append(.header(String(localized: "Files")))
            next.append(contentsOf: fileHits.map { .file($0) })
            if fileMore > 0 {
                next.append(.more(moreLabel(fileMore, capped: false)))
            }
        }
        if scope != .files, !contentHits.isEmpty || contentMore > 0 {
            next.append(.header(String(localized: "Content")))
            next.append(contentsOf: contentHits.map { .content($0) })
            if contentMore > 0 {
                next.append(.more(moreLabel(contentMore, capped: contentCapped)))
            }
        }
        rows = next
        applyRows()
    }

    private func applyRows() {
        let querying = !typedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        empty?.isHidden = !rows.isEmpty || !querying
        table?.reloadData()
        if let table {
            let first = rows.firstIndex { $0.selectable } ?? -1
            if first >= 0 {
                table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
                table.scrollRowToVisible(first)
            } else {
                table.deselectAll(nil)
            }
        }
        resize()
        restoreField()
    }

    private func resize() {
        guard let panel else { return }
        let parent = parentWindow(for: panel)
        let maxHeight = max(220, (parent?.frame.height ?? 800) * 0.6)
        var list: CGFloat = 0
        if let table {
            for index in rows.indices {
                list += tableView(table, heightOfRow: index)
            }
        }
        if rows.isEmpty { list = 80 }
        let height = min(maxHeight, 14 + 36 + 8 + 22 + 6 + list + 8)
        let width = min(640, max(320, (parent?.frame.width ?? 640) - 48))
        var frame = panel.frame
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true)
        place(panel)
    }

    private func place(_ panel: NSWindow) {
        guard let parent = parentWindow(for: panel) else {
            panel.center()
            return
        }
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        let width = panel.frame.width
        let height = panel.frame.height
        let top = parent.frame.height * 0.16
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - width / 2, y: parent.frame.maxY - height - top))
    }

    private func parentWindow(for panel: NSWindow) -> NSWindow? {
        if let parent = panel.parent { return parent }
        return NSApp.keyWindow.flatMap { $0 === panel ? nil : $0 } ?? NSApp.mainWindow
    }

    private func move(_ delta: Int) {
        guard let table else { return }
        let selectable = rows.enumerated().compactMap { $0.element.selectable ? $0.offset : nil }
        guard !selectable.isEmpty else { return }
        let current = selectable.firstIndex(of: table.selectedRow) ?? (delta > 0 ? -1 : 0)
        let next = selectable[min(max(0, current + delta), selectable.count - 1)]
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func openSelection(closePanel: Bool) {
        guard let table, rows.indices.contains(table.selectedRow), let session else { return }
        let row = rows[table.selectedRow]
        guard row.selectable else { return }
        suppressResign = true
        let query = typedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        switch row {
        case .recent(let path):
            session.openRelative(path, pin: true)
        case .file(let hit):
            session.openRelative(hit.relativePath, pin: true)
        case .content(let hit):
            session.openSearchHit(relativePath: hit.relativePath, line: hit.lineNumber, needle: query)
        case .header, .more:
            return
        }
        if closePanel {
            close()
        } else {
            panel?.makeKey()
            if let search { panel?.makeFirstResponder(search) }
            DispatchQueue.main.async { [weak self] in
                self?.suppressResign = false
            }
        }
    }

    private func cycleScope(_ delta: Int) {
        let next = (scope.rawValue + delta + 3) % 3
        setScope(Scope(rawValue: next) ?? .all)
    }

    private func updateChips() {
        for button in chips {
            let on = button.tag == scope.rawValue
            button.state = on ? .on : .off
            button.contentTintColor = on ? .labelColor : .secondaryLabelColor
        }
    }

    fileprivate func close() {
        guard !closing else { return }
        closing = true
        task?.cancel()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        closing = false
        // ⌘K can leave a hidden untitled window behind. Drop it once the panel is gone.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { () -> Void in
                WorkspaceWindowController.closeStrayWindows()
            }
        }
    }

    private func moreLabel(_ count: Int, capped: Bool) -> String {
        if capped {
            return String(format: String(localized: "%lld+ more"), Int64(count))
        }
        return String(format: String(localized: "%lld more"), Int64(count))
    }

    private func reusedText(_ table: NSTableView, id: String) -> SearchCell {
        let identifier = NSUserInterfaceItemIdentifier(id)
        return table.makeView(withIdentifier: identifier, owner: self) as? SearchCell ?? SearchCell(identifier: identifier)
    }

    private func icon(for path: String) -> NSImage? {
        let name = (path as NSString).lastPathComponent
        let symbol = WorkspaceFileSymbolChoice.symbol(name: name, isDirectory: false, isExpanded: false)
        let system: String
        switch symbol {
        case .folder, .folderOpen: system = "folder"
        case .markdown: system = "doc.text"
        case .text: system = "doc.plaintext"
        case .gear: system = "gearshape"
        case .code: system = "chevron.left.forwardslash.chevron.right"
        case .image: system = "photo"
        case .data: system = "curlybraces"
        case .archive: system = "doc.zipper"
        case .document: system = "doc"
        }
        let image = NSImage(systemSymbolName: system, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func nameText(_ path: String) -> NSAttributedString {
        plain((path as NSString).lastPathComponent, size: 13)
    }

    private func parentText(_ path: String) -> NSAttributedString? {
        let parent = parentPath(path)
        guard !parent.isEmpty else { return nil }
        return plain(parent, size: 11, color: .secondaryLabelColor)
    }

    private func pathDetail(_ hit: GlobalFileHit) -> NSAttributedString? {
        let path = hit.relativePath
        guard path != hit.name else { return nil }
        return emphasized(path, indices: hit.pathIndices, size: 11, color: .secondaryLabelColor)
    }

    private func parentPath(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private func headerText(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title.localizedUppercase, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ])
    }

    private func quiet(_ title: String) -> NSAttributedString {
        plain(title, size: 12, color: .secondaryLabelColor)
    }

    private func plain(_ string: String, size: CGFloat, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ])
    }

    private func emphasized(_ string: String, indices: [Int], size: CGFloat, color: NSColor = .labelColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ])
        let emphasis = NSFont.systemFont(ofSize: size, weight: .semibold)
        let wanted = Set(indices)
        var location = 0
        for (offset, character) in string.enumerated() {
            let piece = String(character) as NSString
            if wanted.contains(offset) {
                text.addAttributes([
                    .font: emphasis,
                    .foregroundColor: NSColor.labelColor,
                ], range: NSRange(location: location, length: piece.length))
            }
            location += piece.length
        }
        return text
    }

    private func snippet(_ excerpt: String, query: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: excerpt, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return text }
        let range = (excerpt as NSString).range(of: needle, options: [.caseInsensitive])
        if range.location != NSNotFound {
            text.addAttributes([
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ], range: range)
        }
        return text
    }

    private enum Row {
        case header(String)
        case recent(String)
        case file(GlobalFileHit)
        case content(WorkspaceContentHit)
        case more(String)

        var selectable: Bool {
            switch self {
            case .header, .more: return false
            case .recent, .file, .content: return true
            }
        }
    }
}

/// Keeps the character that `NSSearchField` otherwise drops when it rewrites `stringValue`.
final class QueryField: NSSearchField {
    private var restoring = false

    override func textDidChange(_ notification: Notification) {
        let editor = (notification.userInfo?["NSFieldEditor"] as? NSTextView) ?? (currentEditor() as? NSTextView)
        let live = editor?.string ?? ""
        super.textDidChange(notification)
        guard !restoring, let editor = currentEditor() as? NSTextView, editor.string != live else { return }
        restoring = true
        editor.string = live
        editor.setSelectedRange(NSRange(location: (live as NSString).length, length: 0))
        restoring = false
    }
}

private final class SearchPanel: NSPanel {
    weak var controller: GlobalSearchController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""
        if flags == .command, key == "1" || key == "2" || key == "3" {
            let raw = (key as NSString).integerValue - 1
            let controller = controller
            MainActor.assumeIsolated { () -> Void in
                controller?.setScope(GlobalSearchController.Scope(rawValue: raw) ?? .all)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        let controller = controller
        MainActor.assumeIsolated { () -> Void in
            controller?.close()
        }
    }
}

private final class SearchRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("xyz.search.row")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        bounds.fill()
    }
}

private final class SearchCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        addSubview(icon)
        addSubview(title)
        addSubview(detail)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(title: NSAttributedString, detail: NSAttributedString?, icon: NSImage?) {
        self.icon.image = icon
        self.icon.isHidden = icon == nil
        self.title.attributedStringValue = title
        if let detail, detail.length > 0 {
            self.detail.attributedStringValue = detail
            self.detail.isHidden = false
        } else {
            self.detail.stringValue = ""
            self.detail.isHidden = true
        }
    }
}

/// Types into Find in Files with real key-down events. The field must keep every character.
enum SearchTypingCheck {
    static func run() -> String? {
        MainActor.assumeIsolated { () -> String? in
            typeValue()
        }
    }

    @MainActor
    private static func typeValue() -> String? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xyz-search-keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = WorkspaceSession(rootURL: root, bookmark: nil)
        let controller = GlobalSearchController()
        controller.show(session: session)
        let title = String(localized: "Find in Files")
        guard let panel = NSApp.windows.first(where: { $0.title == title }) else {
            return "search panel did not open"
        }
        guard let field = findField(in: panel.contentView) else {
            controller.closeIfOpen()
            return "search field is missing"
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        let typed = "value1"
        for character in typed {
            let text = String(character)
            guard let down = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: text,
                charactersIgnoringModifiers: text,
                isARepeat: false,
                keyCode: 0
            ) else {
                controller.closeIfOpen()
                return "could not make a key event"
            }
            if let editor = field.currentEditor() {
                editor.keyDown(with: down)
            } else {
                panel.sendEvent(down)
            }
        }
        let shown = (field.currentEditor() as? NSTextView)?.string ?? ""
        if shown != typed {
            controller.closeIfOpen()
            return "search field shows \(shown) after typing \(typed)"
        }
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let after = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        controller.closeIfOpen()
        if after != typed {
            return "search field shows \(after) after the search update"
        }
        return nil
    }

    private static func findField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for child in view.subviews {
            if let found = findField(in: child) { return found }
        }
        return nil
    }
}

#endif
