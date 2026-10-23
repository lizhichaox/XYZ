#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

/// Source-list sidebar. `NSOutlineView` keeps disclosure buttons, icons, and labels on one grid.
struct WorkspaceSidebar: NSViewRepresentable {
    @ObservedObject var session: WorkspaceSession

    func makeNSView(context: Context) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.isEmphasized = true

        let outline = SidebarOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.selectionHighlightStyle = .sourceList
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 16
        outline.rowHeight = 26
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.allowsColumnSelection = false
        outline.backgroundColor = .clear
        outline.autosaveName = nil
        outline.focusRingType = .none
        outline.setAccessibilityLabel("Folder contents")

        let column = NSTableColumn(identifier: SidebarCell.columnID)
        column.title = ""
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = true
        scroll.documentView = outline
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        context.coordinator.outline = outline
        context.coordinator.session = session
        context.coordinator.reloadIfNeeded(force: true)

        outline.onExpand = { [weak coordinator = context.coordinator] item in
            coordinator?.expanded(item, true)
        }
        outline.onCollapse = { [weak coordinator = context.coordinator] item in
            coordinator?.expanded(item, false)
        }
        return effect
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        context.coordinator.session = session
        context.coordinator.reloadIfNeeded(force: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 260, height: proposal.height ?? 600)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        fileprivate weak var outline: SidebarOutlineView?
        var session: WorkspaceSession?
        private var header = SidebarHeader(title: "")
        private var childItems: [String: [NSObject]] = [:]
        private var nodeByPath: [String: SidebarNode] = [:]
        private var snapshot = Snapshot()
        private var suppressSelection = false

        func reloadIfNeeded(force: Bool) {
            guard let session else { return }
            let next = Snapshot(session)
            let treeChanged = force || next != snapshot
            snapshot = next
            if treeChanged {
                rebuild(session)
                applyTree(session)
            }
            syncSelection(session)
        }

        func expanded(_ item: Any, _ isExpanded: Bool) {
            guard let session, let node = item as? SidebarNode else { return }
            guard session.isExpanded(node.relativePath) != isExpanded else { return }
            session.setExpanded(node.model, isExpanded)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return header.title.isEmpty && childItems.isEmpty ? 0 : 1
            }
            if item is SidebarHeader { return childItems[""]?.count ?? 0 }
            if let node = item as? SidebarNode, node.isDirectory {
                return childItems[node.relativePath]?.count ?? 0
            }
            return 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil { return header }
            let key = (item as? SidebarNode)?.relativePath ?? ""
            let rows = childItems[key] ?? []
            if rows.indices.contains(index) { return rows[index] }
            return header
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            if item is SidebarHeader { return true }
            return (item as? SidebarNode)?.isDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            item is SidebarHeader
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? SidebarNode)?.isDirectory == false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            (item as? SidebarNode)?.isDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            if let header = item as? SidebarHeader {
                let cell = reusedHeader(outlineView)
                cell.text = header.title
                return cell
            }
            if let message = item as? SidebarMessage {
                let cell = reusedMessage(outlineView)
                cell.text = message.text
                return cell
            }
            guard let node = item as? SidebarNode else { return nil }
            let cell = reusedRow(outlineView)
            cell.apply(node)
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let session, let outline else { return }
            let row = outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, !node.isDirectory else { return }
            session.openFile(node.model)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let session, let outline, outline.clickedRow >= 0,
                  let node = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
            if !node.isDirectory {
                let open = NSMenuItem(title: "Open with Default App", action: #selector(openWithDefaultApp(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = node.relativePath
                menu.addItem(open)
            }
            let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = node.relativePath
            menu.addItem(reveal)
        }

        @objc private func openWithDefaultApp(_ sender: NSMenuItem) {
            guard let session, let path = sender.representedObject as? String else { return }
            NSWorkspace.shared.open(session.url(for: path))
        }

        @objc private func revealInFinder(_ sender: NSMenuItem) {
            guard let session, let path = sender.representedObject as? String else { return }
            NSWorkspace.shared.activateFileViewerSelecting([session.url(for: path)])
        }

        private func rebuild(_ session: WorkspaceSession) {
            header = SidebarHeader(title: session.displayName)
            childItems = [:]
            nodeByPath = [:]
            if let error = session.rootError {
                childItems[""] = [SidebarMessage(text: error)]
                return
            }
            if session.children[""] == nil {
                childItems[""] = [SidebarMessage(text: "Loading…")]
                return
            }
            fill(session, parent: "")
        }

        private func fill(_ session: WorkspaceSession, parent: String) {
            var rows: [NSObject] = []
            for node in session.visibleChildren(of: parent) {
                let box = SidebarNode(node)
                nodeByPath[node.relativePath] = box
                rows.append(box)
                if node.isDirectory {
                    if session.children[node.relativePath] != nil {
                        fill(session, parent: node.relativePath)
                    } else if let error = session.loadErrors[node.relativePath] {
                        childItems[node.relativePath] = [SidebarMessage(text: error)]
                    } else if session.isExpanded(node.relativePath) {
                        childItems[node.relativePath] = [SidebarMessage(text: "Loading…")]
                    } else {
                        childItems[node.relativePath] = []
                    }
                }
            }
            childItems[parent] = rows
        }

        private func applyTree(_ session: WorkspaceSession) {
            guard let outline else { return }
            suppressSelection = true
            outline.reloadData()
            outline.expandItem(header)
            let expanded = session.expanded.sorted { $0.count < $1.count }
            for path in expanded {
                if let item = nodeByPath[path] {
                    outline.expandItem(item)
                }
            }
            suppressSelection = false
        }

        private func syncSelection(_ session: WorkspaceSession) {
            guard let outline else { return }
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

        private func reusedRow(_ outlineView: NSOutlineView) -> SidebarRowCell {
            if let cell = outlineView.makeView(withIdentifier: SidebarRowCell.identifier, owner: self) as? SidebarRowCell {
                return cell
            }
            return SidebarRowCell()
        }

        private func reusedHeader(_ outlineView: NSOutlineView) -> SidebarTextCell {
            if let cell = outlineView.makeView(withIdentifier: SidebarTextCell.headerID, owner: self) as? SidebarTextCell {
                return cell
            }
            return SidebarTextCell(identifier: SidebarTextCell.headerID, font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold))
        }

        private func reusedMessage(_ outlineView: NSOutlineView) -> SidebarTextCell {
            if let cell = outlineView.makeView(withIdentifier: SidebarTextCell.messageID, owner: self) as? SidebarTextCell {
                return cell
            }
            return SidebarTextCell(identifier: SidebarTextCell.messageID, font: .systemFont(ofSize: NSFont.smallSystemFontSize))
        }
    }
}

private struct Snapshot: Equatable {
    var header = ""
    var showsHidden = true
    var rootError: String?
    var rootLoaded = false
    var nodes: [NodeSnap] = []
    var errors: [String: String] = [:]
    var expanded: [String] = []

    init() {}

    init(_ session: WorkspaceSession) {
        header = session.displayName
        showsHidden = session.showsHiddenFiles
        rootError = session.rootError
        rootLoaded = session.children[""] != nil
        errors = session.loadErrors
        expanded = session.expanded.sorted()
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

private struct NodeSnap: Equatable {
    var path: String
    var name: String
    var isDirectory: Bool
    var isHidden: Bool
    var parent: String
}

private final class SidebarHeader: NSObject {
    let title: String
    init(title: String) { self.title = title }
}

private final class SidebarMessage: NSObject {
    let text: String
    init(text: String) { self.text = text }
}

private final class SidebarNode: NSObject {
    let model: WorkspaceNode
    var relativePath: String { model.relativePath }
    var name: String { model.name }
    var isDirectory: Bool { model.isDirectory }
    var isHidden: Bool { model.isHidden }
    init(_ model: WorkspaceNode) { self.model = model }
}

private final class SidebarOutlineView: NSOutlineView {
    var onExpand: ((Any) -> Void)?
    var onCollapse: ((Any) -> Void)?

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        super.expandItem(item, expandChildren: expandChildren)
        if let item {
            onExpand?(item)
        }
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        super.collapseItem(item, collapseChildren: collapseChildren)
        if let item {
            onCollapse?(item)
        }
    }
}

private enum SidebarCell {
    static let columnID = NSUserInterfaceItemIdentifier("name")
}

private final class SidebarRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("row")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        imageView = icon
        textField = label
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(_ node: SidebarNode) {
        let symbol = Self.symbol(for: node)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = node.isHidden ? .tertiaryLabelColor : .secondaryLabelColor
        label.stringValue = node.name
        label.textColor = node.isHidden ? .secondaryLabelColor : .labelColor
    }

    private static func symbol(for node: SidebarNode) -> String {
        if node.isDirectory { return "folder" }
        let ext = (node.name as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return "doc.text" }
        return "doc"
    }
}

private final class SidebarTextCell: NSTableCellView {
    static let headerID = NSUserInterfaceItemIdentifier("header")
    static let messageID = NSUserInterfaceItemIdentifier("message")

    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, font: NSFont) {
        super.init(frame: .zero)
        self.identifier = identifier
        textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
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
