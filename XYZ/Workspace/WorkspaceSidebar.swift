#if os(macOS)
@preconcurrency import AppKit
import SwiftUI
import XYZCore

/// Source list for one folder. The filter field sits under the toolbar, in the sidebar's top safe area.
struct WorkspaceSidebar: NSViewRepresentable {
    @ObservedObject var session: WorkspaceSession
    var undoManager: UndoManager?

    func makeNSView(context: Context) -> NSView {
        let column = SidebarColumnView()
        let outline = column.outline
        outline.headerView = nil
        outline.style = .plain
        outline.selectionHighlightStyle = .none
        outline.usesAlternatingRowBackgroundColors = false
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 16
        outline.rowHeight = 22
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.allowsColumnSelection = false
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        // Fitting the cell to its text makes the row wider than the sidebar (220 + one indent).
        outline.autoresizesOutlineColumn = false
        outline.indentationMarkerFollowsCell = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.setAccessibilityLabel(String(localized: "Folder contents"))
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let columnID = SidebarCell.columnID
        let tableColumn = NSTableColumn(identifier: columnID)
        tableColumn.title = ""
        tableColumn.resizingMask = .autoresizingMask
        tableColumn.width = 220
        tableColumn.minWidth = 120
        tableColumn.maxWidth = 420
        outline.addTableColumn(tableColumn)
        outline.outlineTableColumn = tableColumn

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        context.coordinator.undoManager = undoManager
        context.coordinator.attach(outline: outline, column: column, session: session)
        context.coordinator.reloadIfNeeded(force: true)

        outline.onExpand = { [weak coordinator = context.coordinator] item in
            coordinator?.expanded(item, true)
        }
        outline.onCollapse = { [weak coordinator = context.coordinator] item in
            coordinator?.expanded(item, false)
        }
        outline.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateSelection()
        }

        column.applySidebarTint()
        return column
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.session = session
        context.coordinator.undoManager = undoManager
        context.coordinator.reloadIfNeeded(force: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 260, height: proposal.height ?? 600)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        private weak var outline: SidebarOutlineView?
        private weak var column: SidebarColumnView?
        weak var undoManager: UndoManager?
        var session: WorkspaceSession?
        private var childItems: [String: [NSObject]] = [:]
        private var rootRows: [NSObject] = []
        private var nodeByPath: [String: SidebarNode] = [:]
        private var snapshot = Snapshot()
        private var suppressSelection = false
        private var suppressExpansionWrite = false
        private var renamingPath: String?

        fileprivate func attach(outline: SidebarOutlineView, column: SidebarColumnView, session: WorkspaceSession) {
            self.outline = outline
            self.column = column
            self.session = session
            column.header.onToggle = { [weak self] in
                self?.toggleRoot()
            }
            column.header.onMenu = { [weak self] event in
                self?.popRootMenu(event)
            }
            outline.target = self
            outline.doubleAction = #selector(pinClickedRow(_:))
        }

        func reloadIfNeeded(force: Bool) {
            guard let session else { return }
            column?.header.onToggle = { [weak self] in
                self?.toggleRoot()
            }
            column?.header.onMenu = { [weak self] event in
                self?.popRootMenu(event)
            }
            syncChrome(session)
            if let message = session.actionMessage {
                session.actionMessage = nil
                present(message)
            }
            let next = Snapshot(session)
            let treeChanged = force || next != snapshot
            if treeChanged {
                // Reloading inside the disclosure-click stack drops the new children.
                queueApply()
            } else {
                syncSelection(session)
            }
        }

        private var applyQueued = false

        /// Rebuild after the outline finishes the click that expanded a folder.
        private func queueApply() {
            guard !applyQueued else { return }
            applyQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyQueued = false
                guard let session = self.session else { return }
                self.snapshot = Snapshot(session)
                self.rebuild(session)
                self.applyTree(session)
                self.syncSelection(session)
            }
        }

        private func toggleRoot() {
            session?.rootExpanded.toggle()
        }

        private func popRootMenu(_ event: NSEvent) {
            guard let header = column?.header else { return }
            let menu = NSMenu()
            menu.addItem(menuItem(String(localized: "Reveal in Finder"), #selector(revealRoot(_:)), ""))
            menu.addItem(menuItem(String(localized: "Copy Path"), #selector(copyRootPath(_:)), ""))
            menu.addItem(.separator())
            menu.addItem(menuItem(String(localized: "Open Folder…"), #selector(switchRootFolder(_:)), ""))
            NSMenu.popUpContextMenu(menu, with: event, for: header)
        }

        private func syncChrome(_ session: WorkspaceSession) {
            guard let column else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            column.header.show(
                name: session.displayName,
                expanded: session.rootExpanded,
                path: WorkspacePaths.abbreviatedHomePath(session.rootURL.path, home: home)
            )
        }

        nonisolated func expanded(_ item: Any, _ isExpanded: Bool) {
            MainActor.assumeIsolated {
                guard !self.suppressExpansionWrite else { return }
                guard let session = self.session, let node = item as? SidebarNode else { return }
                guard session.isExpanded(node.relativePath) != isExpanded else { return }
                session.setExpanded(node.model, isExpanded)
                self.refreshRow(node)
            }
        }

        func activateSelection() {
            guard let session, let outline, outline.selectedRow >= 0 else { return }
            let item = outline.item(atRow: outline.selectedRow)
            if let node = item as? SidebarNode {
                if node.isDirectory {
                    if outline.isItemExpanded(node) {
                        outline.collapseItem(node)
                    } else {
                        outline.expandItem(node)
                    }
                } else {
                    session.openFile(node.model, pin: true)
                    session.focusOpenEditor()
                }
            } else if let hit = item as? SidebarHit {
                session.openRelative(hit.relativePath, pin: true, line: hit.hit.lineNumber)
                session.focusOpenEditor()
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil { return rootRows.count }
            guard let node = item as? SidebarNode, node.isDirectory else { return 0 }
            return childItems[node.relativePath]?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return rootRows.indices.contains(index) ? rootRows[index] : SidebarMessage(text: "")
            }
            let key = (item as? SidebarNode)?.relativePath ?? ""
            let rows = childItems[key] ?? []
            if rows.indices.contains(index) { return rows[index] }
            return SidebarMessage(text: "")
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? SidebarNode)?.isDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            item is SidebarNode || item is SidebarHit
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            (item as? SidebarNode)?.isDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            if item is SidebarSection || item is SidebarMessage { return 18 }
            return 22
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            if let section = item as? SidebarSection {
                let cell = reusedText(outlineView, identifier: SidebarTextCell.sectionID, weight: .semibold)
                cell.text = section.title
                return cell
            }
            if let message = item as? SidebarMessage {
                let cell = reusedText(outlineView, identifier: SidebarTextCell.messageID, weight: .regular)
                cell.text = message.text
                return cell
            }
            if let hit = item as? SidebarHit {
                let cell = reusedRow(outlineView)
                cell.applyHit(hit)
                return cell
            }
            guard let node = item as? SidebarNode else { return nil }
            let cell = reusedRow(outlineView)
            cell.apply(node, expanded: outlineView.isItemExpanded(node))
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = outlineView.makeView(withIdentifier: SidebarRowView.identifier, owner: self) as? SidebarRowView
                ?? SidebarRowView()
            return row
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let session, let outline else { return }
            let row = outline.selectedRow
            guard row >= 0 else { return }
            let item = outline.item(atRow: row)
            if let node = item as? SidebarNode, !node.isDirectory {
                session.openFile(node.model)
            } else if let hit = item as? SidebarHit {
                session.openRelative(hit.relativePath, pin: false, line: hit.hit.lineNumber)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let session, let node = item as? SidebarNode else { return nil }
            return session.url(for: node.relativePath) as NSURL
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: any NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: UnsafeMutablePointer<Int>
        ) -> NSDragOperation {
            guard session != nil, dropParent(for: item) != nil else { return [] }
            guard draggedPaths(from: info).isEmpty == false else { return [] }
            return .move
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: any NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard let session, let parent = dropParent(for: item) else { return false }
            var failed: String?
            for path in draggedPaths(from: info) {
                if let message = session.move(relativePath: path, toParent: parent) {
                    failed = message
                }
            }
            if let failed { present(failed) }
            return failed == nil
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let session, let outline else { return }
            let row = outline.clickedRow
            if row < 0 {
                addCreationItems(menu, parent: "", session: session)
                return
            }
            guard let item = outline.item(atRow: row) else { return }
            if let node = item as? SidebarNode {
                let parent = node.isDirectory ? node.relativePath : WorkspacePaths.parent(of: node.relativePath)
                addCreationItems(menu, parent: parent, session: session)
                menu.addItem(.separator())
                menu.addItem(menuItem(String(localized: "Rename"), #selector(renameItem(_:)), node.relativePath))
                if !node.isDirectory {
                    menu.addItem(menuItem(String(localized: "Open with Default App"), #selector(openExternal(_:)), node.relativePath))
                }
                menu.addItem(menuItem(String(localized: "Reveal in Finder"), #selector(reveal(_:)), node.relativePath))
                menu.addItem(menuItem(String(localized: "Copy Path"), #selector(copyPath(_:)), node.relativePath))
                menu.addItem(menuItem(String(localized: "Copy Relative Path"), #selector(copyRelativePath(_:)), node.relativePath))
                menu.addItem(.separator())
                menu.addItem(menuItem(String(localized: "Move to Trash"), #selector(trashItem(_:)), node.relativePath))
            } else if let hit = item as? SidebarHit {
                menu.addItem(menuItem(String(localized: "Reveal in Finder"), #selector(reveal(_:)), hit.relativePath))
                menu.addItem(menuItem(String(localized: "Copy Path"), #selector(copyPath(_:)), hit.relativePath))
                menu.addItem(menuItem(String(localized: "Copy Relative Path"), #selector(copyRelativePath(_:)), hit.relativePath))
            }
        }

        @objc private func revealRoot(_ sender: Any?) {
            guard let session else { return }
            NSWorkspace.shared.activateFileViewerSelecting([session.rootURL])
        }

        @objc private func copyRootPath(_ sender: Any?) {
            guard let session else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(session.rootURL.path, forType: .string)
        }

        @objc private func switchRootFolder(_ sender: Any?) {
            guard let window = outline?.window ?? column?.window else { return }
            WorkspaceWindowController.controller(for: window)?.promptSwitchFolder()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            guard let session, let path = renamingPath else { return }
            renamingPath = nil
            field.isEditable = false
            field.isBezeled = false
            field.drawsBackground = false
            if let message = session.rename(relativePath: path, to: field.stringValue) {
                present(message)
                reloadIfNeeded(force: true)
            }
        }

        @objc private func renameItem(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            beginRename(path)
        }

        @objc private func openExternal(_ sender: NSMenuItem) {
            guard let session, let path = sender.representedObject as? String else { return }
            NSWorkspace.shared.open(session.url(for: path))
        }

        @objc private func reveal(_ sender: NSMenuItem) {
            guard let session, let path = sender.representedObject as? String else { return }
            NSWorkspace.shared.activateFileViewerSelecting([session.url(for: path)])
        }

        @objc private func pinClickedRow(_ sender: Any?) {
            guard let session, let outline else { return }
            let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
            guard row >= 0, let item = outline.item(atRow: row) else { return }
            if let node = item as? SidebarNode, !node.isDirectory {
                session.openFile(node.model, pin: true)
                session.focusOpenEditor()
            } else if let hit = item as? SidebarHit {
                session.openRelative(hit.relativePath, pin: true, line: hit.hit.lineNumber)
                session.focusOpenEditor()
            }
        }

        @objc private func copyPath(_ sender: NSMenuItem) {
            guard let session, let path = sender.representedObject as? String else { return }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(session.url(for: path).path, forType: .string)
        }

        @objc private func copyRelativePath(_ sender: NSMenuItem) {
            guard let session, let path = sender.representedObject as? String else { return }
            session.copyRelativePath(of: path)
        }

        @objc private func trashItem(_ sender: NSMenuItem) {
            guard let session, let path = sender.representedObject as? String else { return }
            let name = (path as NSString).lastPathComponent
            let alert = NSAlert()
            alert.messageText = String(localized: "Move “\(name)” to the Trash?")
            alert.informativeText = String(localized: "You can recover it from the Trash.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Move to Trash"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModalClosingOnEscape() == .alertFirstButtonReturn else { return }
            do {
                try session.trash(relativePath: path)
            } catch {
                present(String(localized: "Couldn't move this item to the Trash."))
            }
        }

        @objc private func newFile(_ sender: NSMenuItem) {
            guard let session, let parent = sender.representedObject as? String else { return }
            session.createItem(directory: false, in: parent)
        }

        @objc private func newFolder(_ sender: NSMenuItem) {
            guard let session, let parent = sender.representedObject as? String else { return }
            session.createItem(directory: true, in: parent)
        }

        private func beginRename(_ path: String) {
            guard let outline, let item = nodeByPath[path] else { return }
            let row = outline.row(forItem: item)
            guard row >= 0,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarRowCell else { return }
            renamingPath = path
            cell.beginEditing(delegate: self)
        }

        private func addCreationItems(_ menu: NSMenu, parent: String, session: WorkspaceSession) {
            menu.addItem(menuItem(String(localized: "New File"), #selector(newFile(_:)), parent))
            menu.addItem(menuItem(String(localized: "New Folder"), #selector(newFolder(_:)), parent))
        }

        private func menuItem(_ title: String, _ action: Selector, _ path: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = path
            return item
        }

        private func present(_ message: String) {
            let alert = NSAlert()
            alert.messageText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "OK"))
            _ = alert.runModalClosingOnEscape()
        }

        private func rebuild(_ session: WorkspaceSession) {
            childItems = [:]
            nodeByPath = [:]
            rootRows = []
            guard session.rootExpanded else { return }
            if let error = session.rootError {
                rootRows = [SidebarMessage(text: error)]
                return
            }
            if let tree = session.searchTree {
                fill(nodes: tree.children, parent: "", highlights: tree.highlights, lazy: nil, session: session)
                rootRows = childItems[""] ?? []
                if tree.truncated {
                    rootRows.append(SidebarMessage(text: String(localized: "Showing the first \(WorkspaceTreeQuery.matchLimit) name matches.")))
                }
                appendContentHits(session, emptyNames: rootRows.isEmpty)
                if rootRows.isEmpty {
                    rootRows = [SidebarMessage(text: String(localized: "No matches"))]
                }
                return
            }
            if session.children[""] == nil {
                rootRows = [SidebarMessage(text: String(localized: "Loading…"))]
                return
            }
            fill(nodes: nil, parent: "", highlights: [:], lazy: session, session: session)
            rootRows = childItems[""] ?? []
        }

        private func fill(
            nodes: [String: [WorkspaceNode]]?,
            parent: String,
            highlights: [String: [WorkspaceNameSpan]],
            lazy: WorkspaceSession?,
            session: WorkspaceSession
        ) {
            let source = nodes?[parent] ?? lazy?.visibleChildren(of: parent) ?? []
            var rows: [NSObject] = []
            for node in source {
                let box = SidebarNode(node, highlights: highlights[node.relativePath] ?? [])
                nodeByPath[node.relativePath] = box
                rows.append(box)
                guard node.isDirectory else { continue }
                if nodes != nil {
                    fill(nodes: nodes, parent: node.relativePath, highlights: highlights, lazy: nil, session: session)
                } else if session.children[node.relativePath] != nil {
                    fill(nodes: nil, parent: node.relativePath, highlights: [:], lazy: session, session: session)
                } else if let error = session.loadErrors[node.relativePath] {
                    childItems[node.relativePath] = [SidebarMessage(text: error)]
                } else if session.isExpanded(node.relativePath) {
                    childItems[node.relativePath] = [SidebarMessage(text: String(localized: "Loading…"))]
                } else {
                    childItems[node.relativePath] = []
                }
            }
            childItems[parent] = rows
        }

        private func appendContentHits(_ session: WorkspaceSession, emptyNames: Bool) {
            let query = session.nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            if session.contentPatternInvalid {
                rootRows.append(SidebarSection(title: String(localized: "Contents")))
                rootRows.append(SidebarMessage(text: String(localized: "Invalid")))
                return
            }
            guard session.contentSearching || !session.contentHits.isEmpty else { return }
            if !emptyNames {
                rootRows.append(SidebarSection(title: String(localized: "Contents")))
            } else {
                rootRows.append(SidebarSection(title: String(localized: "Contents")))
            }
            if session.contentSearching && session.contentHits.isEmpty {
                rootRows.append(SidebarMessage(text: String(localized: "Searching…")))
            }
            for hit in session.contentHits {
                rootRows.append(SidebarHit(hit))
            }
        }

        private func applyTree(_ session: WorkspaceSession) {
            guard let outline else { return }
            suppressSelection = true
            suppressExpansionWrite = true
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            outline.reloadData()
            let paths: [String]
            if let tree = session.searchTree {
                paths = tree.expanded.sorted { $0.count < $1.count }
            } else {
                paths = session.expanded.sorted { $0.count < $1.count }
            }
            for path in paths {
                if let item = nodeByPath[path] {
                    outline.expandItem(item)
                }
            }
            NSAnimationContext.endGrouping()
            suppressExpansionWrite = false
            suppressSelection = false
            if let path = session.pendingEditPath, nodeByPath[path] != nil {
                session.pendingEditPath = nil
                beginRename(path)
            }
        }

        private func syncSelection(_ session: WorkspaceSession) {
            guard let outline, renamingPath == nil else { return }
            let path = session.buffer?.relativePath ?? session.selectedPath
            let current: String?
            if outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode {
                current = node.relativePath
            } else {
                current = nil
            }
            guard current != path else { return }
            suppressSelection = true
            defer { suppressSelection = false }
            let filePath = path
            guard let filePath else {
                outline.deselectAll(nil)
                outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
                return
            }
            var parent = WorkspacePaths.parent(of: filePath)
            while !parent.isEmpty {
                if let item = nodeByPath[parent] {
                    outline.expandItem(item, expandChildren: false)
                }
                parent = WorkspacePaths.parent(of: parent)
            }
            guard let item = nodeByPath[filePath] else { return }
            let row = outline.row(forItem: item)
            guard row >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        }

        private func refreshRow(_ node: SidebarNode) {
            guard let outline else { return }
            let row = outline.row(forItem: node)
            guard row >= 0,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRowCell else { return }
            cell.apply(node, expanded: outline.isItemExpanded(node))
        }

        private func dropParent(for item: Any?) -> String? {
            if item == nil { return "" }
            guard let node = item as? SidebarNode else { return nil }
            return node.isDirectory ? node.relativePath : WorkspacePaths.parent(of: node.relativePath)
        }

        private func draggedPaths(from info: any NSDraggingInfo) -> [String] {
            guard let session else { return [] }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            let root = session.rootURL.standardizedFileURL.path
            return urls.compactMap { url in
                let full = url.standardizedFileURL.path
                let prefix = root + "/"
                guard full.hasPrefix(prefix) else { return nil }
                return String(full.dropFirst(prefix.count))
            }
        }

        private func reusedRow(_ outlineView: NSOutlineView) -> SidebarRowCell {
            if let cell = outlineView.makeView(withIdentifier: SidebarRowCell.identifier, owner: self) as? SidebarRowCell {
                return cell
            }
            return SidebarRowCell()
        }

        private func reusedText(_ outlineView: NSOutlineView, identifier: NSUserInterfaceItemIdentifier, weight: NSFont.Weight) -> SidebarTextCell {
            if let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarTextCell {
                return cell
            }
            return SidebarTextCell(identifier: identifier, weight: weight)
        }
    }
}

fileprivate final class SidebarColumnView: NSView {
    let header = SidebarRootHeader()
    let scroll = NSScrollView()
    let outline = SidebarOutlineView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let explorer = NSTextField(labelWithString: "")
        explorer.translatesAutoresizingMaskIntoConstraints = false
        explorer.attributedStringValue = NSAttributedString(
            string: String(localized: "Explorer").localizedUppercase,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ]
        )
        explorer.setAccessibilityLabel(String(localized: "Explorer"))

        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = true
        scroll.documentView = outline

        addSubview(explorer)
        addSubview(header)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            explorer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            explorer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            explorer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: explorer.bottomAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        applySidebarTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySidebarTint()
    }

    func applySidebarTint() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.xyzSidebar.cgColor
        outline.backgroundColor = .xyzSidebar
        outline.enclosingScrollView?.drawsBackground = false
    }

    override func viewWillDraw() {
        fitRowsToSidebar()
        super.viewWillDraw()
    }

    override func layout() {
        super.layout()
        fitRowsToSidebar()
    }

    /// The outline's own fitting width is wider than the clip until the editor lays out.
    /// Pin the column to the sidebar before the first paint, including when no file is open.
    private func fitRowsToSidebar() {
        let visible = scroll.contentSize.width > 1 ? scroll.contentSize.width : scroll.bounds.width
        guard visible > 1, let column = outline.tableColumns.first else { return }
        if abs(column.width - visible) > 0.5 || column.minWidth != visible || column.maxWidth != visible {
            column.minWidth = visible
            column.maxWidth = visible
            column.width = visible
        }
        if abs(outline.frame.width - visible) > 0.5 {
            var frame = outline.frame
            frame.size.width = visible
            outline.frame = frame
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// The open folder's name. A chevron collapses the tree. The tooltip is the path with ~ for home.
fileprivate final class SidebarRootHeader: NSView {
    var onToggle: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    private let chevron = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.imageScaling = .scaleProportionallyDown
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(chevron)
        addSubview(label)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(name: String, expanded: Bool, path: String) {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.attributedStringValue = NSAttributedString(string: name.localizedUppercase, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ])
        let symbol = expanded ? "chevron.down" : "chevron.right"
        let description = expanded ? String(localized: "Collapse") : String(localized: "Expand")
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        chevron.contentTintColor = .secondaryLabelColor
        toolTip = path
        setAccessibilityLabel(name)
        setAccessibilityHelp(path)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

@MainActor
fileprivate struct Snapshot: Equatable {
    var showsHidden = true
    var rootError: String?
    var rootLoaded = false
    var query = ""
    var nodes: [NodeSnap] = []
    var errors: [String: String] = [:]
    var expanded: [String] = []
    var hitIDs: [String] = []
    var contentSearching = false
    var contentPatternInvalid = false
    var rootExpanded = true
    var indexCount = 0

    init() {}

    init(_ session: WorkspaceSession) {
        showsHidden = session.showsHiddenFiles
        rootError = session.rootError
        rootLoaded = session.children[""] != nil
        query = session.nameQuery
        errors = session.loadErrors
        expanded = session.expanded.sorted()
        hitIDs = session.contentHits.map(\.id)
        contentSearching = session.contentSearching
        contentPatternInvalid = session.contentPatternInvalid
        rootExpanded = session.rootExpanded
        indexCount = session.indexedEntries.count
        if let tree = session.searchTree {
            var collected: [NodeSnap] = []
            func walk(_ parent: String) {
                for node in tree.children[parent] ?? [] {
                    collected.append(NodeSnap(
                        path: node.relativePath,
                        name: node.name,
                        isDirectory: node.isDirectory,
                        isHidden: node.isHidden,
                        parent: parent
                    ))
                    if node.isDirectory {
                        walk(node.relativePath)
                    }
                }
            }
            walk("")
            nodes = collected
            return
        }
        var collected: [NodeSnap] = []
        func walk(_ parent: String) {
            for node in session.visibleChildren(of: parent) {
                collected.append(NodeSnap(
                    path: node.relativePath,
                    name: node.name,
                    isDirectory: node.isDirectory,
                    isHidden: node.isHidden,
                    parent: parent
                ))
                if node.isDirectory, session.children[node.relativePath] != nil {
                    walk(node.relativePath)
                }
            }
        }
        if rootLoaded {
            walk("")
        }
        nodes = collected
    }
}

fileprivate struct NodeSnap: Equatable {
    var path: String
    var name: String
    var isDirectory: Bool
    var isHidden: Bool
    var parent: String
}

fileprivate final class SidebarSection: NSObject {
    let title: String
    init(title: String) { self.title = title }
}

fileprivate final class SidebarMessage: NSObject {
    let text: String
    init(text: String) { self.text = text }
}

fileprivate final class SidebarHit: NSObject {
    let hit: WorkspaceContentHit
    var relativePath: String { hit.relativePath }
    init(_ hit: WorkspaceContentHit) { self.hit = hit }
}

fileprivate final class SidebarNode: NSObject {
    let model: WorkspaceNode
    let highlights: [WorkspaceNameSpan]
    var relativePath: String { model.relativePath }
    var name: String { model.name }
    var isDirectory: Bool { model.isDirectory }
    var isHidden: Bool { model.isHidden }
    init(_ model: WorkspaceNode, highlights: [WorkspaceNameSpan]) {
        self.model = model
        self.highlights = highlights
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SidebarNode else { return false }
        return other.relativePath == relativePath
    }

    override var hash: Int { relativePath.hashValue }
}

fileprivate final class SidebarOutlineView: NSOutlineView {
    var onExpand: ((Any) -> Void)?
    var onCollapse: ((Any) -> Void)?
    var onActivate: (() -> Void)?

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        super.expandItem(item, expandChildren: expandChildren)
        if let item { onExpand?(item) }
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        super.collapseItem(item, collapseChildren: collapseChildren)
        if let item { onCollapse?(item) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawIndentGuides()
    }

    /// Quiet vertical rules at each indent, in the gutter beside the disclosure triangles.
    private func drawIndentGuides() {
        let rowRange = rows(in: visibleRect)
        guard rowRange.length > 0, indentationPerLevel > 0 else { return }
        NSColor.separatorColor.withAlphaComponent(0.9).setStroke()
        let step = indentationPerLevel
        for row in rowRange.location..<(rowRange.location + rowRange.length) {
            let level = level(forRow: row)
            guard level > 0 else { continue }
            let rect = rect(ofRow: row)
            for depth in 1...level {
                let x = (CGFloat(depth) - 0.5) * step
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x, y: rect.minY))
                path.line(to: NSPoint(x: x, y: rect.maxY))
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    private var hoveredRow = -1
    private var hoverTracking: NSTrackingArea?

    var hoveredRowIndex: Int { hoveredRow }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        hoverTracking = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredRow(-1)
    }

    override func reloadData() {
        hoveredRow = -1
        super.reloadData()
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        setHoveredRow(row)
    }

    private func setHoveredRow(_ row: Int) {
        let next = row >= 0 && row < numberOfRows ? row : -1
        guard next != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = next
        if previous >= 0, let view = rowView(atRow: previous, makeIfNecessary: false) {
            view.needsDisplay = true
        }
        if next >= 0, let view = rowView(atRow: next, makeIfNecessary: false) {
            view.needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onActivate?()
        case 123:
            if !nudge(expand: false) { super.keyDown(with: event) }
        case 124:
            if !nudge(expand: true) { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    /// Right opens a folder or steps into it. Left closes it, or moves to the parent.
    private func nudge(expand: Bool) -> Bool {
        let row = selectedRow
        guard row >= 0, let item = item(atRow: row) else { return false }
        if expand {
            guard let node = item as? SidebarNode, node.isDirectory else { return false }
            if isItemExpanded(node) {
                guard numberOfChildren(ofItem: node) > 0 else { return true }
                let child = child(0, ofItem: node)
                let childRow = self.row(forItem: child)
                guard childRow >= 0 else { return true }
                selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
                scrollRowToVisible(childRow)
            } else {
                self.expandItem(node)
            }
            return true
        }
        if let node = item as? SidebarNode, node.isDirectory, isItemExpanded(node) {
            collapseItem(node)
            return true
        }
        guard let parent = parent(forItem: item) else { return false }
        let parentRow = self.row(forItem: parent)
        guard parentRow >= 0 else { return false }
        selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
        scrollRowToVisible(parentRow)
        return true
    }
}

fileprivate enum SidebarCell {
    static let columnID = NSUserInterfaceItemIdentifier("name")
}

/// One selected row, and a hover fill only while the pointer is on that row.
fileprivate final class SidebarRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar.row")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        selectionHighlightStyle = .none
        super.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground(in: dirtyRect)
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {
        guard let outline = enclosingOutline else { return }
        let row = outline.row(for: self)
        guard row >= 0 else { return }
        if outline.selectedRow == row {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            bounds.fill()
        } else if outline.hoveredRowIndex == row {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            bounds.fill()
        }
    }

    private var enclosingOutline: SidebarOutlineView? {
        var view: NSView? = superview
        while let current = view {
            if let outline = current as? SidebarOutlineView { return outline }
            view = current.superview
        }
        return nil
    }
}

fileprivate final class SidebarRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("row")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var fullName = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        imageView = icon
        textField = label
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.symbolConfiguration = config
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.allowsDefaultTighteningForTruncation = true
        label.font = .systemFont(ofSize: 12)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private var rowNode: SidebarNode?
    private var rowExpanded = false
    private var rowHit: SidebarHit?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColors() }
    }

    fileprivate func apply(_ node: SidebarNode, expanded: Bool) {
        rowNode = node
        rowExpanded = expanded
        rowHit = nil
        fullName = node.name
        toolTip = node.name
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        refreshColors()
    }

    fileprivate func applyHit(_ hit: SidebarHit) {
        rowNode = nil
        rowHit = hit
        let name = (hit.relativePath as NSString).lastPathComponent
        fullName = name
        toolTip = "\(hit.relativePath) — line \(hit.hit.lineNumber)"
        label.lineBreakMode = .byTruncatingTail
        refreshColors()
    }

    private func refreshColors() {
        // The row draws a grey bar, so the text stays the normal label color.
        if let node = rowNode {
            let symbol = WorkspaceFileSymbolChoice.symbol(
                name: node.name,
                isDirectory: node.isDirectory,
                isExpanded: rowExpanded
            )
            icon.image = Self.image(symbol)
            let base: NSColor = node.isHidden ? .secondaryLabelColor : .labelColor
            icon.contentTintColor = node.isHidden ? .secondaryLabelColor : .secondaryLabelColor
            label.attributedStringValue = Self.nameText(
                node.name,
                base: base,
                quiet: base,
                highlights: node.highlights,
                dimExtension: false
            )
            return
        }
        guard let hit = rowHit else { return }
        let name = (hit.relativePath as NSString).lastPathComponent
        let symbol = WorkspaceFileSymbolChoice.symbol(name: name, isDirectory: false, isExpanded: false)
        icon.image = Self.image(symbol)
        let primary: NSColor = .labelColor
        let quiet: NSColor = .tertiaryLabelColor
        icon.contentTintColor = quiet
        let combined = hit.hit.excerpt.isEmpty ? name : name + "  " + hit.hit.excerpt
        let text = NSMutableAttributedString(string: combined)
        let font = NSFont.systemFont(ofSize: 12)
        let full = NSRange(location: 0, length: (combined as NSString).length)
        text.addAttributes([.font: font, .foregroundColor: primary], range: full)
        if !hit.hit.excerpt.isEmpty {
            let excerptRange = NSRange(
                location: (name as NSString).length,
                length: (combined as NSString).length - (name as NSString).length
            )
            text.addAttributes([
                .foregroundColor: quiet,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ], range: excerptRange)
        }
        label.attributedStringValue = text
    }

    func beginEditing(delegate: NSTextFieldDelegate) {
        label.stringValue = fullName
        label.isEditable = true
        label.isSelectable = true
        label.isBezeled = true
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.textColor = .labelColor
        label.delegate = delegate
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectedRange = NSRange(location: 0, length: (fullName as NSString).length)
    }

    private static func image(_ symbol: WorkspaceFileSymbol) -> NSImage? {
        let name: String
        switch symbol {
        case .folder, .folderOpen: name = "folder"
        case .markdown: name = "doc.text"
        case .text: name = "doc.plaintext"
        case .gear: name = "gearshape"
        case .code: name = "chevron.left.forwardslash.chevron.right"
        case .image: name = "photo"
        case .data: name = "curlybraces"
        case .archive: name = "doc.zipper"
        case .document: name = "doc"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private static func nameText(
        _ name: String,
        base: NSColor,
        quiet: NSColor,
        highlights: [WorkspaceNameSpan],
        dimExtension: Bool
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name)
        let font = NSFont.systemFont(ofSize: 12)
        let full = NSRange(location: 0, length: (name as NSString).length)
        text.addAttributes([.font: font, .foregroundColor: base], range: full)
        if dimExtension, let span = WorkspaceFileSymbolChoice.extensionSpan(in: name) {
            let range = NSRange(location: span.location, length: span.length)
            if NSMaxRange(range) <= full.length {
                text.addAttribute(.foregroundColor, value: quiet, range: range)
            }
        }
        let emphasis = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for span in highlights {
            let range = NSRange(location: span.location, length: span.length)
            guard range.location >= 0, NSMaxRange(range) <= full.length, range.length > 0 else { continue }
            text.addAttribute(.font, value: emphasis, range: range)
        }
        return text
    }
}

fileprivate final class SidebarTextCell: NSTableCellView {
    static let sectionID = NSUserInterfaceItemIdentifier("section")
    static let messageID = NSUserInterfaceItemIdentifier("message")

    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, weight: NSFont.Weight) {
        super.init(frame: .zero)
        self.identifier = identifier
        textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: weight)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}
#endif
