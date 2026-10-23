#if os(macOS)
@preconcurrency import AppKit
import SwiftUI
import XYZCore

/// Source list for one folder. The filter field sits under the toolbar, in the sidebar's top safe area.
struct WorkspaceSidebar: NSViewRepresentable {
    @ObservedObject var session: WorkspaceSession

    func makeNSView(context: Context) -> NSView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let usesGlass = Self.glassSearch(reduceTransparency: reduceTransparency)
        let column = SidebarColumnView(usesGlass: usesGlass)
        let outline = column.outline
        outline.headerView = nil
        outline.style = .sourceList
        outline.selectionHighlightStyle = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 15
        outline.rowHeight = 24
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.allowsColumnSelection = false
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.autoresizesOutlineColumn = true
        outline.setAccessibilityLabel("Folder contents")
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        let columnID = SidebarCell.columnID
        let tableColumn = NSTableColumn(identifier: columnID)
        tableColumn.title = ""
        tableColumn.resizingMask = .autoresizingMask
        outline.addTableColumn(tableColumn)
        outline.outlineTableColumn = tableColumn

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        column.search.delegate = context.coordinator
        context.coordinator.attach(outline: outline, search: column.search, session: session)
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

        if #available(macOS 26, *), usesGlass {
            column.wantsLayer = true
            column.layer?.backgroundColor = NSColor.clear.cgColor
            return column
        }
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.isEmphasized = !reduceTransparency
        column.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            column.topAnchor.constraint(equalTo: effect.topAnchor),
            column.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.session = session
        context.coordinator.reloadIfNeeded(force: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 260, height: proposal.height ?? 600)
    }

    private static func glassSearch(reduceTransparency: Bool) -> Bool {
        guard !reduceTransparency else { return false }
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
        private weak var outline: SidebarOutlineView?
        private weak var search: SidebarSearchField?
        var session: WorkspaceSession?
        private var childItems: [String: [NSObject]] = [:]
        private var rootRows: [NSObject] = []
        private var nodeByPath: [String: SidebarNode] = [:]
        private var snapshot = Snapshot()
        private var suppressSelection = false
        private var suppressExpansionWrite = false
        private var renamingPath: String?

        fileprivate func attach(outline: SidebarOutlineView, search: SidebarSearchField, session: WorkspaceSession) {
            self.outline = outline
            self.search = search
            self.session = session
            search.onEscape = { [weak self] in
                self?.escapeSearch()
            }
            session.focusSearchHandler = { [weak self] in
                self?.focusSearch()
            }
        }

        func reloadIfNeeded(force: Bool) {
            guard let session else { return }
            session.focusSearchHandler = { [weak self] in
                self?.focusSearch()
            }
            if let message = session.actionMessage {
                session.actionMessage = nil
                present(message)
            }
            let next = Snapshot(session)
            let treeChanged = force || next != snapshot
            snapshot = next
            if let search, search.stringValue != session.nameQuery, search.currentEditor() == nil {
                search.stringValue = session.nameQuery
            }
            if treeChanged {
                rebuild(session)
                applyTree(session)
            }
            syncSelection(session)
        }

        func focusSearch() {
            guard let search else { return }
            search.window?.makeFirstResponder(search)
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
                    session.openFile(node.model)
                }
            } else if let hit = item as? SidebarHit {
                session.openRelative(hit.relativePath)
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
            if item is SidebarSection || item is SidebarMessage { return 22 }
            return 24
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

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let session, let outline else { return }
            let row = outline.selectedRow
            guard row >= 0 else { return }
            let item = outline.item(atRow: row)
            if let node = item as? SidebarNode, !node.isDirectory {
                session.openFile(node.model)
            } else if let hit = item as? SidebarHit {
                session.openRelative(hit.relativePath)
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
                menu.addItem(menuItem("Rename", #selector(renameItem(_:)), node.relativePath))
                if !node.isDirectory {
                    menu.addItem(menuItem("Open with Default App", #selector(openExternal(_:)), node.relativePath))
                }
                menu.addItem(menuItem("Reveal in Finder", #selector(reveal(_:)), node.relativePath))
                menu.addItem(menuItem("Copy Path", #selector(copyPath(_:)), node.relativePath))
                menu.addItem(.separator())
                menu.addItem(menuItem("Move to Trash", #selector(trashItem(_:)), node.relativePath))
            } else if let hit = item as? SidebarHit {
                menu.addItem(menuItem("Reveal in Finder", #selector(reveal(_:)), hit.relativePath))
                menu.addItem(menuItem("Copy Path", #selector(copyPath(_:)), hit.relativePath))
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field === search else { return }
            session?.nameQuery = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let search, field !== search else { return }
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

        @objc private func copyPath(_ sender: NSMenuItem) {
            guard let session, let path = sender.representedObject as? String else { return }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(session.url(for: path).path, forType: .string)
        }

        @objc private func trashItem(_ sender: NSMenuItem) {
            guard let session, let path = sender.representedObject as? String else { return }
            let name = (path as NSString).lastPathComponent
            let alert = NSAlert()
            alert.messageText = "Move “\(name)” to the Trash?"
            alert.informativeText = "You can recover it from the Trash."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try session.trash(relativePath: path)
            } catch {
                present("Couldn't move this item to the Trash.")
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

        private func escapeSearch() {
            guard let session else { return }
            if session.nameQuery.isEmpty {
                outline?.window?.makeFirstResponder(outline)
            } else {
                session.clearQuery()
                search?.stringValue = ""
            }
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
            menu.addItem(menuItem("New File", #selector(newFile(_:)), parent))
            menu.addItem(menuItem("New Folder", #selector(newFolder(_:)), parent))
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
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        private func rebuild(_ session: WorkspaceSession) {
            childItems = [:]
            nodeByPath = [:]
            rootRows = []
            if let error = session.rootError {
                rootRows = [SidebarMessage(text: error)]
                return
            }
            if let tree = session.searchTree {
                fill(nodes: tree.children, parent: "", highlights: tree.highlights, lazy: nil, session: session)
                rootRows = childItems[""] ?? []
                if tree.truncated {
                    rootRows.append(SidebarMessage(text: "Showing the first \(WorkspaceTreeQuery.matchLimit) name matches."))
                }
                appendContentHits(session, emptyNames: rootRows.isEmpty)
                if rootRows.isEmpty {
                    rootRows = [SidebarMessage(text: "No matches")]
                }
                return
            }
            if session.children[""] == nil {
                rootRows = [SidebarMessage(text: "Loading…")]
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
                    childItems[node.relativePath] = [SidebarMessage(text: "Loading…")]
                } else {
                    childItems[node.relativePath] = []
                }
            }
            childItems[parent] = rows
        }

        private func appendContentHits(_ session: WorkspaceSession, emptyNames: Bool) {
            let query = session.nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            guard session.contentSearching || !session.contentHits.isEmpty else { return }
            if !emptyNames {
                rootRows.append(SidebarSection(title: "Contents"))
            } else {
                rootRows.append(SidebarSection(title: "Contents"))
            }
            if session.contentSearching && session.contentHits.isEmpty {
                rootRows.append(SidebarMessage(text: "Searching…"))
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
            let path = session.selectedPath
            let current: String?
            if outline.selectedRow >= 0, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode {
                current = node.relativePath
            } else {
                current = nil
            }
            guard current != path else { return }
            suppressSelection = true
            defer { suppressSelection = false }
            guard let path, let item = nodeByPath[path] else { return }
            let row = outline.row(forItem: item)
            guard row >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
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
    let search: SidebarSearchField
    let scroll = NSScrollView()
    let outline = SidebarOutlineView()
    private let glassHost: NSView?

    init(usesGlass: Bool) {
        let search = SidebarSearchField()
        self.search = search
        if usesGlass, #available(macOS 26, *) {
            search.translatesAutoresizingMaskIntoConstraints = false
            search.isBordered = false
            search.drawsBackground = false
            let glass = NSGlassEffectView()
            glass.cornerRadius = 14
            glass.style = .regular
            glass.contentView = search
            glassHost = glass
        } else {
            glassHost = nil
        }
        super.init(frame: .zero)
        search.placeholderString = "Filter"
        search.sendsSearchStringImmediately = true
        search.controlSize = .small
        search.focusRingType = .none
        search.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        search.setAccessibilityLabel("Filter files")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = true
        scroll.documentView = outline
        if let glassHost {
            addSubview(glassHost)
        } else {
            addSubview(search)
        }
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let topInset = safeAreaInsets.top + 8
        let margin: CGFloat = 10
        let height: CGFloat = 28
        let field = NSRect(
            x: margin,
            y: bounds.height - topInset - height,
            width: max(0, bounds.width - margin * 2),
            height: height
        )
        if let glassHost {
            glassHost.frame = field
            if #available(macOS 26, *), let glass = glassHost as? NSGlassEffectView {
                glass.cornerRadius = field.height / 2
            }
        } else {
            search.frame = field
        }
        let used = topInset + height + 6
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - used))
    }
}

fileprivate final class SidebarSearchField: NSSearchField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76:
            onActivate?()
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rowRange = rows(in: dirtyRect)
        guard rowRange.location != NSNotFound, rowRange.length > 0 else { return }
        let strong = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let color = NSColor.separatorColor.withAlphaComponent(strong ? 0.95 : 0.4)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let last = rowRange.location + rowRange.length
        for row in rowRange.location..<last {
            guard let item = item(atRow: row) else { continue }
            let level = level(forItem: item)
            guard level > 0 else { continue }
            let rect = rect(ofRow: row)
            for ancestor in 1...level {
                let x = floor(CGFloat(ancestor) * indentationPerLevel + 8) + 0.5
                path.move(to: NSPoint(x: x, y: rect.minY))
                path.line(to: NSPoint(x: x, y: rect.maxY))
            }
        }
        path.stroke()
    }
}

fileprivate enum SidebarCell {
    static let columnID = NSUserInterfaceItemIdentifier("name")
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
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.symbolConfiguration = config
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.allowsDefaultTighteningForTruncation = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
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

    fileprivate func apply(_ node: SidebarNode, expanded: Bool) {
        fullName = node.name
        toolTip = node.name
        let symbol = WorkspaceFileSymbolChoice.symbol(
            name: node.name,
            isDirectory: node.isDirectory,
            isExpanded: expanded
        )
        icon.image = Self.image(symbol)
        let strong = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        icon.contentTintColor = node.isHidden ? .tertiaryLabelColor : (strong ? .labelColor : .secondaryLabelColor)
        let base: NSColor = node.isHidden ? .secondaryLabelColor : .labelColor
        label.attributedStringValue = Self.nameText(
            node.name,
            base: base,
            highlights: node.highlights,
            dimExtension: true
        )
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
    }

    fileprivate func applyHit(_ hit: SidebarHit) {
        let name = (hit.relativePath as NSString).lastPathComponent
        fullName = name
        toolTip = "\(hit.relativePath) — line \(hit.hit.lineNumber)"
        let symbol = WorkspaceFileSymbolChoice.symbol(name: name, isDirectory: false, isExpanded: false)
        icon.image = Self.image(symbol)
        icon.contentTintColor = .tertiaryLabelColor
        let combined = hit.hit.excerpt.isEmpty ? name : name + "  " + hit.hit.excerpt
        let text = NSMutableAttributedString(string: combined)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let full = NSRange(location: 0, length: (combined as NSString).length)
        text.addAttributes([
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ], range: full)
        if !hit.hit.excerpt.isEmpty {
            let excerptRange = NSRange(location: (name as NSString).length, length: (combined as NSString).length - (name as NSString).length)
            text.addAttributes([
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            ], range: excerptRange)
        }
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingTail
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
        case .folder: name = "folder"
        case .folderOpen: name = "folder.fill"
        case .markdown: name = "doc.text"
        case .text: name = "doc.plaintext"
        case .gear: name = "gearshape"
        case .document: name = "doc"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private static func nameText(
        _ name: String,
        base: NSColor,
        highlights: [WorkspaceNameSpan],
        dimExtension: Bool
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let full = NSRange(location: 0, length: (name as NSString).length)
        text.addAttributes([.font: font, .foregroundColor: base], range: full)
        if dimExtension, let span = WorkspaceFileSymbolChoice.extensionSpan(in: name) {
            let range = NSRange(location: span.location, length: span.length)
            if NSMaxRange(range) <= full.length {
                text.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
            }
        }
        let emphasis = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
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
