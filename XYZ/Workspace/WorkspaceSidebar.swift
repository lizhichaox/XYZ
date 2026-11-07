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
        outline.indentationPerLevel = OutlineDisclosure.step
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
        tableColumn.minWidth = 80
        tableColumn.maxWidth = 8_000
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

        outline.onExpand = { [weak coordinator = context.coordinator, weak outline] item in
            coordinator?.expanded(item, true, user: outline?.marksUserExpansion == true)
        }
        outline.onCollapse = { [weak coordinator = context.coordinator, weak outline] item in
            coordinator?.expanded(item, false, user: outline?.marksUserExpansion == true)
        }
        outline.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateSelection()
        }
        outline.onExpansionApplied = { [weak coordinator = context.coordinator] in
            guard let coordinator, let session = coordinator.session else { return }
            coordinator.recordAppliedSnapshot(session)
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
        /// Node objects reused across rebuilds. `NSOutlineView` keeps its expansion by
        /// object identity; fresh objects on every rebuild made it drop open rows.
        private var nodeCache: [String: SidebarNode] = [:]
        /// Paths that exist in the tree being rebuilt; `nodeCache` is pruned to these.
        private var seenPaths: Set<String> = []
        /// True while the expansion change is the user's (click, key, Collapse All).
        /// AppKit's own collapses during a reload must not edit the session.
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
            wireHeaderActions()
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
            wireHeaderActions()
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
        /// Bumped whenever the view already shows the newest state, so a rebuild queued
        /// earlier does not run over the user's click and swallow it.
        private var applyGeneration = 0

        /// The view already shows the current expansion. Recording the snapshot here
        /// keeps the next update from rebuilding the tree for a change it can see.
        fileprivate func recordAppliedSnapshot(_ session: WorkspaceSession) {
            snapshot = Snapshot(session)
            applyQueued = false
            applyGeneration += 1
        }

        /// Rebuild after the outline finishes the click that expanded a folder.
        private func queueApply() {
            guard !applyQueued else { return }
            applyQueued = true
            applyGeneration += 1
            let generation = applyGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.applyGeneration else { return }
                self.applyQueued = false
                guard let session = self.session else { return }
                self.snapshot = Snapshot(session)
                self.rebuild(session)
                self.applyTree(session)
                self.syncSelection(session)
            }
        }

        private func toggleRoot() {
            guard let session else { return }
            session.rootExpanded = ExplorerSection.toggle(session.rootExpanded)
            XYZDiagnostics.note("explorer section expanded=\(session.rootExpanded)")
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

        private func wireHeaderActions() {
            column?.header.onNewFile = { [weak self] in
                guard let session = self?.session else { return }
                session.createItem(directory: false, in: session.creationParent())
            }
            column?.header.onNewFolder = { [weak self] in
                guard let session = self?.session else { return }
                session.createItem(directory: true, in: session.creationParent())
            }
            column?.header.onRefresh = { [weak self] in
                self?.session?.refreshFileTree()
            }
            column?.header.onCollapseAll = { [weak self] in
                guard let self, let session = self.session else { return }
                // The selected folder first: the button then opens or closes that one,
                // not every folder in the tree.
                if let path = session.clickedPath ?? session.selectedPath,
                   let selected = session.node(at: path),
                   selected.isDirectory,
                   let item = self.nodeByPath[path] {
                    self.outline?.marksUserExpansion = true
                    if self.outline?.isItemExpanded(item) == true {
                        self.outline?.collapseItem(item)
                    } else {
                        self.outline?.expandItem(item)
                    }
                    self.outline?.marksUserExpansion = false
                    self.refreshRow(item)
                    return
                }
                if session.expanded.isEmpty {
                    self.expandRootFolders(session)
                } else {
                    session.collapseAllFolders()
                    self.collapseAllRows()
                }
            }
        }

        /// Opens the folders at the top of the tree, which is what the button does when
        /// nothing is open. Loading every descendant at once is not attempted: a folder's
        /// children are read when it opens.
        private func expandRootFolders(_ session: WorkspaceSession) {
            let roots = session.visibleChildren(of: "").filter(\.isDirectory)
            for node in roots where !session.isExpanded(node.relativePath) {
                session.setExpanded(node, true)
            }
        }

        /// Closes every row the outline shows open.
        ///
        /// `reloadData()` restores the expansion of items that still compare equal, so
        /// clearing `session.expanded` alone left every folder on screen open: that is
        /// why Collapse All did nothing. Closing the rows here keeps the view and the
        /// session in step; the next rebuild has nothing to restore.
        private func collapseAllRows() {
            guard let outline else { return }
            var open: [Any] = []
            for row in 0..<outline.numberOfRows {
                guard let item = outline.item(atRow: row), outline.isItemExpanded(item) else { continue }
                open.append(item)
            }
            guard !open.isEmpty else { return }
            suppressExpansionWrite = true
            let animatesDisclosureWasOn = outline.animatesDisclosure
            outline.animatesDisclosure = false
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            for item in open.reversed() {
                outline.collapseItem(item)
            }
            NSAnimationContext.endGrouping()
            outline.animatesDisclosure = animatesDisclosureWasOn
            suppressExpansionWrite = false
            if let session { recordAppliedSnapshot(session) }
        }

        private func syncChrome(_ session: WorkspaceSession) {
            guard let column else { return }
            if let path = session.clickedPath ?? session.selectedPath,
               let selected = session.node(at: path),
               selected.isDirectory {
                column.header.showCollapseButton(collapses: session.isExpanded(path), focused: true)
            } else {
                column.header.showCollapseButton(collapses: !session.expanded.isEmpty, focused: false)
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            column.header.show(
                name: session.displayName,
                expanded: session.rootExpanded,
                path: WorkspacePaths.abbreviatedHomePath(session.rootURL.path, home: home)
            )
            column.setTreeVisible(session.rootExpanded)
        }

        nonisolated func expanded(_ item: Any, _ isExpanded: Bool, user: Bool) {
            MainActor.assumeIsolated {
                // Only the user's own open/close edits the session. AppKit drives the
                // same callbacks while it reloads the outline, and writing those back
                // closed folders the user had just opened.
                guard user, !self.suppressExpansionWrite else { return }
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
                    recordAppliedSnapshot(session)
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
            let openPath = (outlineView as? SidebarOutlineView)?.openRelativePath
            cell.apply(
                node,
                expanded: outlineView.isItemExpanded(node),
                open: node.relativePath == openPath
            )
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = outlineView.makeView(withIdentifier: SidebarRowView.identifier, owner: self) as? SidebarRowView
                ?? SidebarRowView()
            return row
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            if let outline, outline.selectedRow >= 0 {
                let item = outline.item(atRow: outline.selectedRow)
            }
            guard !suppressSelection, let session, let outline else { return }
            let row = outline.selectedRow
            guard row >= 0 else { return }
            let item = outline.item(atRow: row)
            if let node = item as? SidebarNode {
                // The clicked row is remembered without publishing: a folder click only
                // moves the sidebar highlight, and publishing redrew the whole window.
                session.clickedPath = node.relativePath
                if !node.isDirectory {
                    session.selectedPath = node.relativePath
                    session.openFile(node.model)
                }
            } else if let hit = item as? SidebarHit {
                session.clickedPath = hit.relativePath
                session.selectedPath = hit.relativePath
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
            let movement = notification.userInfo?["NSTextMovement"] as? Int
            if movement == NSTextMovement.cancel.rawValue {
                reloadIfNeeded(force: true)
                return
            }
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
            seenPaths = []
            defer { nodeCache = nodeCache.filter { seenPaths.contains($0.key) } }
            defer { publishPlaceholder(session) }
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

        /// A lone status line, or an empty tree, sits in the middle of the list. Nested rows stay put.
        private func publishPlaceholder(_ session: WorkspaceSession) {
            guard session.rootExpanded else {
                column?.setPlaceholder(nil)
                return
            }
            if rootRows.isEmpty {
                column?.setPlaceholder(String(localized: "No Files"))
                return
            }
            if rootRows.count == 1, let message = rootRows[0] as? SidebarMessage {
                column?.setPlaceholder(message.text)
                rootRows = []
                return
            }
            column?.setPlaceholder(nil)
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
                let box: SidebarNode
                if let cached = nodeCache[node.relativePath] {
                    cached.model = node
                    cached.highlights = highlights[node.relativePath] ?? []
                    box = cached
                } else {
                    box = SidebarNode(node, highlights: highlights[node.relativePath] ?? [])
                    nodeCache[node.relativePath] = box
                }
                nodeByPath[node.relativePath] = box
                seenPaths.insert(node.relativePath)
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
            outline.animatesDisclosure = false
            let selectedBefore = (outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) : nil)
                .flatMap { ($0 as? SidebarNode)?.relativePath }
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
            outline.animatesDisclosure = true
            suppressExpansionWrite = false
            suppressSelection = false
            // A row built before its folder was opened keeps the closed glyph. Re-apply
            // every visible row's cell once the expansion state is final.
            outline.enumerateAvailableRowViews { _, row in
                guard let item = outline.item(atRow: row),
                      let node = item as? SidebarNode,
                      let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRowCell
                else { return }
                cell.apply(node, expanded: outline.isItemExpanded(node), open: node.relativePath == outline.openRelativePath)
            }
            // Rows moved: put the highlight back on the row the user had, not on
            // whatever now sits at the old row number.
            if let keep = session.clickedPath ?? session.selectedPath ?? selectedBefore, let item = nodeByPath[keep] {
                let row = outline.row(forItem: item)
                if row >= 0, outline.selectedRow != row {
                    suppressSelection = true
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    suppressSelection = false
                    outline.scrollRowToVisible(row)
                }
            }
            if let path = session.pendingEditPath, nodeByPath[path] != nil {
                session.pendingEditPath = nil
                beginRename(path)
            }
        }

        private var lastSyncedPath: String?

        private func syncSelection(_ session: WorkspaceSession) {
            guard let outline, renamingPath == nil else { return }
            // A rebuild used to put the selection back on the open file after the user had
            // clicked a folder, so a click in the sidebar never seemed to select anything.
            // Follow the open file only when it actually changed.
            // The row the user clicked wins over the open file: clicking a folder must
            // not jump back to the file that happens to be open.
            let pathNow = session.selectedPath ?? session.buffer?.relativePath
            if pathNow == lastSyncedPath, outline.selectedRow >= 0 { return }
            lastSyncedPath = pathNow
            let path = session.buffer?.relativePath ?? session.selectedPath
            let current: String?
            if outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode {
                current = node.relativePath
            } else {
                current = nil
            }
            let explicitReveal = session.consumeSidebarReveal()
            guard current != path else { return }
            suppressSelection = true
            defer { suppressSelection = false }
            let filePath = path
            outline.openRelativePath = filePath
            guard session.rootExpanded, let filePath else {
                outline.deselectAll(nil)
                outline.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
                return
            }
            let parents = SidebarReveal.ancestorsToExpand(
                of: filePath,
                explicitReveal: explicitReveal
            )
            if !parents.isEmpty {
                outline.animatesDisclosure = false
                suppressExpansionWrite = true
                for parent in parents {
                    if let item = nodeByPath[parent] {
                        outline.expandItem(item, expandChildren: false)
                    }
                }
                suppressExpansionWrite = false
                outline.animatesDisclosure = true
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
            cell.apply(node, expanded: outline.isItemExpanded(node), open: node.relativePath == outline.openRelativePath)
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

/// Chooses the outline column width. The clip view is a few dozen points until the scroll view lays out, and that stub must not win over a sidebar that is already hundreds of points wide.
enum SidebarColumnWidth {
    static func resolve(clip: CGFloat, scroll: CGFloat, view: CGFloat) -> (width: CGFloat, source: String)? {
        if clip > 1, scroll > 1, clip >= scroll - 24 {
            return (clip, "clip")
        }
        if scroll > 1 {
            return (scroll, "scroll")
        }
        if view > 1 {
            return (view, "view")
        }
        return nil
    }
}

/// CI check that a 34 point pre-layout clip cannot pin the outline column to its 80 point minimum.
enum SidebarColumnFitCheck {
    static func run() -> String? {
        let stub = SidebarColumnWidth.resolve(clip: 34, scroll: 437, view: 437)
        if stub?.source != "scroll" || abs((stub?.width ?? 0) - 437) > 0.5 {
            return "sidebar column used the pre-layout clip"
        }
        let early = SidebarColumnWidth.resolve(clip: 34, scroll: 0, view: 437)
        if early?.source != "view" || abs((early?.width ?? 0) - 437) > 0.5 {
            return "sidebar column used the pre-layout clip before the scroll view existed"
        }
        let laidOut = SidebarColumnWidth.resolve(clip: 437, scroll: 437, view: 437)
        if laidOut?.source != "clip" || abs((laidOut?.width ?? 0) - 437) > 0.5 {
            return "sidebar column ignored the laid-out clip"
        }
        let view = SidebarColumnView(frame: NSRect(x: 0, y: 0, width: 437, height: 500))
        let tableColumn = NSTableColumn(identifier: SidebarCell.columnID)
        tableColumn.resizingMask = .autoresizingMask
        tableColumn.width = 220
        tableColumn.minWidth = 120
        tableColumn.maxWidth = 420
        view.outline.autoresizesOutlineColumn = false
        view.outline.addTableColumn(tableColumn)
        view.outline.outlineTableColumn = tableColumn
        print("GUTTER_STAGE sidebar")
        fflush(stdout)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let width = view.outline.tableColumns.first?.width ?? 0
        if width < 400 {
            return "sidebar column \(width) in a 437pt sidebar"
        }
        let latin = SidebarContentMeasure.explorerRow(String(repeating: "i", count: 12), depth: 0)
        let cjk = SidebarContentMeasure.explorerRow(String(repeating: "文", count: 12), depth: 0)
        if cjk <= latin {
            return "sidebar fit treated 12 Chinese characters as no wider than 12 i's \(cjk) \(latin)"
        }
        let nested = SidebarContentMeasure.explorerRow("note.md", depth: 3)
        let top = SidebarContentMeasure.explorerRow("note.md", depth: 0)
        if nested <= top {
            return "sidebar fit ignored nesting \(nested) \(top)"
        }
        let shortName = SidebarContentMeasure.explorerRow("a.md", depth: 0)
        let longName = SidebarContentMeasure.explorerRow(String(repeating: "Very Long File Name ", count: 4), depth: 0)
        if longName <= shortName {
            return "sidebar fit ignored a long file name"
        }
        let header = SidebarContentMeasure.header("XYZ")
        if header < 4 * 22 {
            return "sidebar fit left no room for the header actions \(header)"
        }
        if SidebarContentMeasure.explorerRow("a.md", depth: 1) != SidebarContentMeasure.explorerRow("a.md", depth: 1) {
            return "sidebar fit changed on the same name"
        }
        let deep = SidebarContentMeasure.outlineRow(String(repeating: "节", count: 8), depth: 4)
        let shallow = SidebarContentMeasure.outlineRow("A", depth: 0)
        if deep <= shallow {
            return "outline fit ignored a deep Chinese heading"
        }
        if SidebarContentMeasure.outline([]) < SidebarFit.outlineMinimum {
            return "outline fit gave an empty panel no width"
        }
        let split = XYZSplitView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        split.install(
            sidebar: NSView(),
            detail: NSView(),
            outline: NSView(),
            showsSidebar: true,
            showsOutline: true,
            outlineWidth: 220
        )
        var leftFits = 0
        var rightFits = 0
        split.measureSidebar = {
            leftFits += 1
            return 300
        }
        split.measureOutline = {
            rightFits += 1
            return 240
        }
        split.testingDoubleClick(left: true)
        split.testingDoubleClick(left: false)
        if leftFits != 1 || rightFits != 1 {
            return "divider double-click did not call both fit hooks \(leftFits) \(rightFits)"
        }
        return nil
    }
}

fileprivate final class SidebarColumnView: NSView {
    let header = SidebarRootHeader()
    let scroll = NSScrollView()
    let outline = SidebarOutlineView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let explorer = NSTextField(labelWithString: "")
        explorer.translatesAutoresizingMaskIntoConstraints = false
        explorer.attributedStringValue = NSAttributedString(
            string: String(localized: "Explorer").localizedUppercase,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.xyzSecondaryText,
                .kern: 0.6,
            ]
        )
        explorer.setAccessibilityLabel(String(localized: "Explorer"))

        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.contentView.backgroundColor = .xyzSidebar
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = true
        scroll.documentView = outline
        observeClip()

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.maximumNumberOfLines = 4
        placeholder.lineBreakMode = .byWordWrapping
        placeholder.isHidden = true
        placeholder.setAccessibilityIdentifier("xyz.sidebar.placeholder")

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
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -16),
        ])
        didFinishInit = true
    }

    func setTreeVisible(_ visible: Bool) {
        scroll.isHidden = !visible
        if !visible { setPlaceholder(nil) }
        needsDisplay = true
    }

    func setPlaceholder(_ text: String?) {
        let next = text ?? ""
        placeholder.stringValue = next
        placeholder.isHidden = next.isEmpty
        placeholder.preferredMaxLayoutWidth = max(0, scroll.bounds.width - 32)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        applySidebarTint()
        guard didFinishInit else { return }
        fitRowsToSidebar(reason: "window")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySidebarTint()
    }

    override var isOpaque: Bool { true }

    /// Fill in `draw` so the color follows the appearance. A layer `CGColor` captured
    /// outside that pass stays white, and collapse uncovers it.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.xyzSidebar.setFill()
        dirtyRect.fill()
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.xyzSidebar.cgColor
        }
    }

    func applySidebarTint() {
        wantsLayer = false
        layer?.backgroundColor = nil
        needsDisplay = true
        outline.backgroundColor = .xyzSidebar
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.contentView.backgroundColor = .xyzSidebar
        outline.enclosingScrollView?.drawsBackground = false
    }

    override func viewWillDraw() {
        if didFinishInit {
            fitRowsToSidebar(reason: "draw")
        }
        super.viewWillDraw()
    }

    override func layout() {
        super.layout()
        guard didFinishInit else { return }
        placeholder.preferredMaxLayoutWidth = max(0, scroll.bounds.width - 32)
        fitRowsToSidebar(reason: "layout")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard didFinishInit else { return }
        fitRowsToSidebar(reason: "frame")
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard didFinishInit else { return }
        fitRowsToSidebar(reason: "liveResize")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The clip view posts frame and bounds changes. Its width is a stub until the scroll view tiles, so the fitter also runs from layout.
    private func observeClip() {
        let clip = scroll.contentView
        clip.postsFrameChangedNotifications = true
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipGeometryChanged(_:)), name: NSView.frameDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(clipGeometryChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func clipGeometryChanged(_ notification: Notification) {
        guard didFinishInit else { return }
        let clip = scroll.contentView
        let width = max(clip.frame.width, clip.bounds.width)
        guard abs(width - lastClipWidth) > 0.5 else { return }
        lastClipWidth = width
        let reason = notification.name == NSView.frameDidChangeNotification ? "clipFrame" : "clipBounds"
        fitRowsToSidebar(reason: reason)
    }

    /// Pin the outline column to the width the sidebar actually has, including the first layout and every later clip change.
    private func fitRowsToSidebar(reason: String) {
        guard !fitting, let column = outline.tableColumns.first else { return }
        let clipBounds = scroll.contentView.bounds.width
        let clipFrame = scroll.contentView.frame.width
        let scrollWidth = scroll.bounds.width
        let viewWidth = bounds.width
        guard let decision = SidebarColumnWidth.resolve(clip: clipFrame, scroll: scrollWidth, view: viewWidth) else { return }
        let width = decision.width
        let needsApply = abs(width - appliedWidth) > 0.5
            || abs(column.width - width) > 0.5
            || abs(outline.frame.width - width) > 0.5
        let clipChanged = abs(clipFrame - lastLoggedClip) > 0.5 || decision.source != lastLoggedSource
        guard needsApply || clipChanged else { return }
        if needsApply {
            if abs(width - fitBudgetWidth) > 0.5 {
                fitBudgetWidth = width
                fitBudget = 0
            }
            fitBudget += 1
            // A layout that keeps resetting the document must not run forever.
            guard fitBudget <= 4 else { return }
            fitting = true
            defer { fitting = false }
            appliedWidth = width
            column.minWidth = min(80, width)
            column.maxWidth = max(8_000, width)
            column.width = width
            if abs(outline.frame.width - width) > 0.5 {
                var frame = outline.frame
                frame.size.width = width
                outline.frame = frame
            }
            if abs(column.width - width) > 0.5 {
                column.width = width
            }
            outline.enumerateAvailableRowViews { row, _ in
                guard abs(row.frame.width - width) > 0.5 else { return }
                var frame = row.frame
                frame.size.width = width
                row.frame = frame
                row.needsLayout = true
            }
        }
        lastLoggedClip = clipFrame
        lastLoggedSource = decision.source
        XYZDiagnostics.note(String(
            format: "sidebar column=%.1f view=%.1f scroll=%.1f clip=%.1f clipFrame=%.1f source=%@ reason=%@",
            column.width, viewWidth, scrollWidth, clipBounds, clipFrame, decision.source, reason
        ))
    }

    private var didFinishInit = false
    private var fitting = false
    private var appliedWidth = CGFloat(-1)
    private var lastClipWidth = CGFloat(-1)
    private var lastLoggedClip = CGFloat(-1)
    private var lastLoggedSource = ""
    private var fitBudget = 0
    private var fitBudgetWidth = CGFloat(-1)

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// The open folder's name. A chevron collapses the tree. The tooltip is the path with ~ for home.
fileprivate final class SidebarRootHeader: NSView {
    var onToggle: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onNewFile: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onCollapseAll: (() -> Void)?
    /// The button that closes every folder, or opens them again when they are closed.
    private let collapseButton = ExplorerHeaderButton(
        symbol: "rectangle.compress.vertical",
        title: String(localized: "Collapse All")
    )
    private let chevron = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private var expanded = true

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
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.orientation = .horizontal
        actions.spacing = 0
        actions.alignment = .centerY
        actions.setHuggingPriority(.required, for: .horizontal)
        let specs: [(String, String, Selector)] = [
            ("doc.badge.plus", String(localized: "New File"), #selector(newFile(_:))),
            ("folder.badge.plus", String(localized: "New Folder"), #selector(newFolder(_:))),
            ("arrow.clockwise", String(localized: "Refresh Explorer"), #selector(refreshTree(_:))),
        ]
        for spec in specs {
            let button = ExplorerHeaderButton(symbol: spec.0, title: spec.1)
            button.target = self
            button.action = spec.2
            actions.addArrangedSubview(button)
        }
        collapseButton.target = self
        collapseButton.action = #selector(collapseAll(_:))
        actions.addArrangedSubview(collapseButton)
        addSubview(chevron)
        addSubview(label)
        addSubview(actions)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// True when at least one folder is open, so the button collapses. False means the
    /// button will open the folders again, and its glyph points that way.
    /// `focused` means the button acts on the selected folder only, so its title drops
    /// the "All". The glyph always says what a click will do.
    func showCollapseButton(collapses: Bool, focused: Bool) {
        let collapseTitle = focused ? String(localized: "Collapse") : String(localized: "Collapse All")
        let expandTitle = focused ? String(localized: "Expand") : String(localized: "Expand All")
        if collapses {
            collapseButton.show(symbol: "rectangle.compress.vertical", title: collapseTitle)
        } else {
            collapseButton.show(symbol: "rectangle.expand.vertical", title: expandTitle)
        }
    }

    func show(name: String, expanded: Bool, path: String) {
        self.expanded = expanded
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.attributedStringValue = NSAttributedString(string: name.localizedUppercase, attributes: [
            .font: font,
            .foregroundColor: NSColor.xyzSecondaryText,
            .kern: 0.6,
        ])
        applyChevron()
        toolTip = path
        let state = expanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        setAccessibilityLabel("\(name), \(state)")
        setAccessibilityHelp(path)
    }

    @objc private func newFile(_ sender: Any?) { onNewFile?() }
    @objc private func newFolder(_ sender: Any?) { onNewFolder?() }
    @objc private func refreshTree(_ sender: Any?) { onRefresh?() }
    @objc private func collapseAll(_ sender: Any?) { onCollapseAll?() }

    override func layout() {
        super.layout()
        applyChevron()
    }

    /// A real symbol, not a rotated frame. Layout resets a frame rotation, which left the twisty stuck.
    private func applyChevron() {
        let symbol = expanded ? "chevron.down" : "chevron.right"
        let description = expanded ? String(localized: "Collapse") : String(localized: "Expand")
        chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        chevron.contentTintColor = .xyzSecondaryText
        chevron.setAccessibilityLabel(description)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if actions.frame.contains(local) {
            return actions.hitTest(local) ?? actions
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if actions.frame.contains(local) { return }
        onToggle?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

/// Compact Explorer action. Idle is transparent, so the white sidebar stays white.
fileprivate final class ExplorerHeaderButton: NSControl {
    private var symbol: String
    private var titleText: String
    private var hovered = false
    private var pressed = false

    /// Changes the glyph, tooltip and accessibility title together (Collapse All vs
    /// Expand All).
    fileprivate func show(symbol: String, title: String) {
        guard symbol != self.symbol || title != titleText else { return }
        self.symbol = symbol
        self.titleText = title
        toolTip = title
        setAccessibilityLabel(title)
        needsDisplay = true
    }

    init(symbol: String, title: String) {
        self.symbol = symbol
        self.titleText = title
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = title
        setAccessibilityLabel(title)
        setAccessibilityRole(.button)
        refusesFirstResponder = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        pressed = true
        needsDisplay = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if pressed != inside {
                pressed = inside
                needsDisplay = true
            }
            if next.type == .leftMouseUp {
                if inside { sendAction(action, to: target) }
                break
            }
        }
        pressed = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            sendAction(action, to: target)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        if hovered || pressed || focused {
            let alpha: CGFloat = pressed ? 0.18 : 0.10
            NSColor.xyzSecondaryText.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: titleText)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) else { return }
        let tint = isEnabled ? NSColor.xyzSecondaryText : NSColor.xyzSecondaryText.withAlphaComponent(0.35)
        let side: CGFloat = 14
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        image.tinted(with: tint).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let copy = NSImage(size: size)
        copy.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        color.set()
        rect.fill()
        draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
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
    var model: WorkspaceNode
    var highlights: [WorkspaceNameSpan]
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
    /// True while the user's own click or key drives the change. AppKit also calls
    /// `expandItem`/`collapseItem` while it reloads; those must not edit the session.
    var marksUserExpansion = false
    /// Called after the view changed a folder's state, so the list can remember that the
    /// change is already on screen and skip a rebuild.
    var onExpansionApplied: (() -> Void)?
    var onActivate: (() -> Void)?

    /// Opening and closing a folder lands in one frame. The eased version drew AppKit's
    /// own intermediate disclosure frames, which put the triangle at the left edge for a
    /// moment before it settled.
    var animatesDisclosure = false
    var openRelativePath: String?

    /// A click on a folder's disclosure opens or closes it here, not inside AppKit.
    ///
    /// AppKit puts its own button in the disclosure slot, and that button only acts while
    /// its window is tracking the mouse; a click delivered without that tracking (the
    /// acceptance check, an inactive window) was dropped, and the folder stayed closed.
    /// The row view leaves this strip to the outline so this method always sees it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let r = row(at: point)
        if togglesFolder(at: point) { return }
        let clickedRow = r
        super.mouseDown(with: event)
        // A row click also opens or closes a folder, the way a sidebar does in VS Code
        // and Obsidian. Every click of a quick series counts: AppKit numbers them
        // 1, 2, 3... and skipping the later ones meant the folder opened once and then
        // could not be closed while the user kept clicking.
        let rowNow = row(at: point)
        guard clickedRow >= 0, clickedRow == rowNow else { return }
        guard let item = item(atRow: clickedRow), let node = item as? SidebarNode, node.isDirectory else {
            return
        }
        if let window {
            let released = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard hypot(released.x - point.x, released.y - point.y) <= 4 else {
                return
            }
        }
        toggle(node)
        refreshGlyph(of: node)
    }

    /// The row's folder glyph follows the disclosure state.
    fileprivate func refreshGlyph(of node: SidebarNode) {
        let row = row(forItem: node)
        guard row >= 0,
              let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRowCell
        else { return }
        cell.apply(node, expanded: isItemExpanded(node), open: node.relativePath == openRelativePath)
    }

    /// Opens or closes the folder whose disclosure strip holds `point`. Returns true when
    /// the click belonged to a folder's disclosure and was handled.
    fileprivate func togglesFolder(at point: NSPoint) -> Bool {
        let clickedRow = row(at: point)
        guard clickedRow >= 0, let item = item(atRow: clickedRow),
              let node = item as? SidebarNode, node.isDirectory
        else { return false }
        let strip = disclosureStrip(atRow: clickedRow)
        guard strip.contains(point) else { return false }
        toggle(node)
        return true
    }

    /// One user open/close, marked as the user's so the session follows it.
    fileprivate func toggle(_ node: SidebarNode) {
        let wasExpanded = isItemExpanded(node)
        let animated = animatesDisclosure
        animatesDisclosure = false
        marksUserExpansion = true
        if wasExpanded {
            collapseItem(node)
        } else {
            expandItem(node)
        }
        marksUserExpansion = false
        onExpansionApplied?()
        animatesDisclosure = animated
        // The rows that appeared were laid out during the change; ask for their final
        // geometry and a redraw, so no frame keeps the pre-layout triangle position.
        needsLayout = true
        enumerateAvailableRowViews { _, row in
            guard let item = item(atRow: row),
                  let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRowCell,
                  let node = item as? SidebarNode
            else { return }
            cell.apply(node, expanded: isItemExpanded(node), open: node.relativePath == openRelativePath)
        }
    }

    /// A little wider than the triangle, so the click does not have to be exact.
    fileprivate func disclosureStrip(atRow row: Int) -> NSRect {
        frameOfOutlineCell(atRow: row).insetBy(dx: -3, dy: -2)
    }

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        instant { super.expandItem(item, expandChildren: expandChildren) }
        if let item { onExpand?(item) }
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        instant { super.collapseItem(item, collapseChildren: collapseChildren) }
        if let item { onCollapse?(item) }
    }

    /// One frame, no intermediate rows. Any animation here draws AppKit's own layout
    /// frames, and those are where the disclosure appeared at the left edge for a
    /// moment before settling.
    private func instant(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        body()
        NSAnimationContext.endGrouping()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawIndentGuides()
    }

    /// Level-0 twisties are drawn left of the cell. A flush-left window then clips them off the screen.

    /// Quiet vertical rules at each indent, in the gutter beside the disclosure triangles.
    private func drawIndentGuides() {
        let rowRange = rows(in: visibleRect)
        guard rowRange.length > 0, indentationPerLevel > 0 else { return }
        NSColor.xyzDivider.setStroke()
        let step = indentationPerLevel
        for row in rowRange.location..<(rowRange.location + rowRange.length) {
            let level = level(forRow: row)
            guard level > 0 else { continue }
            let rect = rect(ofRow: row)
            for depth in 1...level {
                let x = CGFloat(depth) * step + 8
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

    /// The disclosure strip belongs to the outline view, so a triangle click reaches
    /// `SidebarOutlineView.mouseDown` instead of AppKit's private disclosure button.
    /// That button only acts inside its own mouse tracking, and a click delivered
    /// without it (the acceptance check, an inactive window) was dropped.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let outline = superview as? SidebarOutlineView {
            let local = convert(point, from: superview)
            let inOutline = outline.convert(local, from: self)
            let row = outline.row(at: inOutline)
            if row >= 0, outline.disclosureStrip(atRow: row).contains(inOutline) {
                return nil
            }
        }
        return super.hitTest(point)
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {
        guard let outline = enclosingOutline else { return }
        let row = outline.row(for: self)
        guard row >= 0 else { return }
        // One row is selected. The open file is marked on its name instead (see
        // `SidebarRowCell.refreshColors`); filling it here as well drew two highlights,
        // and after clicking a folder it looked like the file was still selected.
        if outline.selectedRow == row {
            NSColor.xyzSelection.setFill()
            bounds.fill()
        } else if outline.hoveredRowIndex == row {
            NSColor.xyzAccent.withAlphaComponent(0.06).setFill()
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

/// A label that never takes a click. `NSTextField` is an `NSControl`: it handled the
/// mouse itself, so a click on a folder's name never reached the outline view and the
/// folder could not be opened from its name.
fileprivate final class SidebarPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

fileprivate final class SidebarRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("row")

    private let icon = NSImageView()
    private let label = SidebarPassthroughLabel(labelWithString: "")
    private var fullName = ""
    private var rowOpen = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        imageView = icon
        textField = label
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.symbolConfiguration = config
        icon.contentTintColor = .xyzSecondaryText
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
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

    override func layout() {
        super.layout()
    }

    private var rowNode: SidebarNode?
    private var rowExpanded = false
    private var rowHit: SidebarHit?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { refreshColors() }
    }

    fileprivate func apply(_ node: SidebarNode, expanded: Bool, open: Bool = false) {
        rowNode = node
        rowExpanded = expanded
        rowOpen = open
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
        // The open file is an accent tint, so the name stays ink.
        if let node = rowNode {
            let symbol = WorkspaceFileSymbolChoice.symbol(
                name: node.name,
                isDirectory: node.isDirectory,
                isExpanded: rowExpanded
            )
            icon.image = Self.image(symbol)
            let base: NSColor = node.isHidden ? .xyzSecondaryText : (rowOpen ? .xyzAccent : .xyzInk)
            icon.contentTintColor = rowOpen ? .xyzAccent : .xyzSecondaryText
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

    private let label = SidebarPassthroughLabel(labelWithString: "")

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
