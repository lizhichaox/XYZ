#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

struct WorkspaceActions {
    var showsHidden: Bool
    var toggleHidden: () -> Void
    var focusSearch: () -> Void
}

private struct WorkspaceActionsKey: FocusedValueKey {
    typealias Value = WorkspaceActions
}

extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

/// Explorer, editor, and the Markdown outline. Each edge is a hairline with a grab strip on top of the panes.
private struct WorkspaceSplit<Sidebar: View, Detail: View, Outline: View>: NSViewRepresentable {
    var showsSidebar: Bool
    var showsOutline: Bool
    var outlineWidth: CGFloat
    var onOutlineWidth: (CGFloat) -> Void
    var sidebar: Sidebar
    var detail: Detail
    var outline: Outline

    init(
        showsSidebar: Bool,
        showsOutline: Bool,
        outlineWidth: CGFloat,
        onOutlineWidth: @escaping (CGFloat) -> Void,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder outline: () -> Outline
    ) {
        self.showsSidebar = showsSidebar
        self.showsOutline = showsOutline
        self.outlineWidth = outlineWidth
        self.onOutlineWidth = onOutlineWidth
        self.sidebar = sidebar()
        self.detail = detail()
        self.outline = outline()
    }

    func makeNSView(context: Context) -> XYZSplitView {
        let split = XYZSplitView()
        let side = NSHostingView(rootView: sidebar)
        let main = NSHostingView(rootView: detail)
        let outlineHost = NSHostingView(rootView: outline)
        side.sizingOptions = [.minSize]
        main.sizingOptions = [.minSize]
        outlineHost.sizingOptions = [.minSize]
        context.coordinator.side = side
        context.coordinator.detail = main
        context.coordinator.outline = outlineHost
        split.onOutlineWidth = onOutlineWidth
        split.install(
            sidebar: side,
            detail: main,
            outline: outlineHost,
            showsSidebar: showsSidebar,
            showsOutline: showsOutline,
            outlineWidth: outlineWidth
        )
        return split
    }

    func updateNSView(_ split: XYZSplitView, context: Context) {
        context.coordinator.side?.rootView = sidebar
        context.coordinator.detail?.rootView = detail
        context.coordinator.outline?.rootView = outline
        split.onOutlineWidth = onOutlineWidth
        split.setSidebarShown(showsSidebar)
        split.setOutline(shown: showsOutline, width: outlineWidth)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var side: NSHostingView<Sidebar>?
        var detail: NSHostingView<Detail>?
        var outline: NSHostingView<Outline>?
    }
}

/// The panes sit in an `NSSplitView` with no divider of its own. The hairlines are separate
/// views in front of the editor, so a web view or text view cannot take the resize cursor.
final class XYZSplitView: NSView, NSSplitViewDelegate {
    fileprivate var sidebar: NSView?
    fileprivate var detail: NSView?
    fileprivate var outline: NSView?
    var onOutlineWidth: ((CGFloat) -> Void)?
    private let panes = PaneSplitView()
    private let leftDivider = SidebarDivider(edge: .left)
    private let rightDivider = SidebarDivider(edge: .right)
    private var savedPosition: CGFloat = 260
    private var savedOutline: CGFloat = 220
    private var sidebarShown = true
    private var outlineShown = false
    private var adjusting = false
    private var chromeAnimating = false
    private var chromeTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        panes.isVertical = true
        panes.dividerStyle = .thin
        panes.delegate = self
        panes.autosaveName = nil
        panes.autoresizingMask = [.width, .height]
        addSubview(panes)
        addSubview(leftDivider)
        addSubview(rightDivider)
        leftDivider.boundaryX = { [weak self] in
            self?.sidebar?.frame.maxX ?? 0
        }
        leftDivider.moveTo = { [weak self] position in
            self?.moveDivider(.left, to: position)
        }
        rightDivider.boundaryX = { [weak self] in
            self?.detail?.frame.maxX ?? 0
        }
        rightDivider.moveTo = { [weak self] position in
            self?.moveDivider(.right, to: position)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        if panes.frame != bounds {
            panes.frame = bounds
        }
        guard !adjusting, bounds.width > 1 else {
            placeDividers()
            return
        }
        adjusting = true
        if !chromeAnimating, sidebarShown, let sidebar, sidebar.superview != nil, sidebar.frame.width < 200 {
            let room = bounds.width - (outlineShown ? savedOutline : 0) - 480
            panes.setPosition(min(max(savedPosition, 220), max(220, room)), ofDividerAt: 0)
        }
        applyOutlineWidthIfNeeded()
        adjusting = false
        placeDividers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateDividerCursors()
    }

    func install(
        sidebar: NSView,
        detail: NSView,
        outline: NSView,
        showsSidebar: Bool,
        showsOutline: Bool,
        outlineWidth: CGFloat
    ) {
        self.sidebar = sidebar
        self.detail = detail
        self.outline = outline
        sidebarShown = showsSidebar
        outlineShown = showsOutline
        savedOutline = outlineWidth
        rebuild()
        applyPositions()
    }

    func setSidebarShown(_ shown: Bool) {
        guard shown != sidebarShown else { return }
        if sidebarShown, let sidebar, sidebar.superview != nil, sidebar.frame.width > 1 {
            savedPosition = max(220, sidebar.frame.width)
        }
        sidebarShown = shown
        XYZDiagnostics.note("sidebar shown=\(shown)")
        if shown {
            rebuild()
            slideDivider(0, to: 0)
            slideDivider(0, to: savedPosition, animated: true)
        } else {
            slideDivider(0, to: 0, animated: true) { [weak self] in
                self?.rebuild()
                self?.placeDividers()
            }
        }
    }

    func setOutline(shown: Bool, width: CGFloat) {
        if !chromeAnimating {
            savedOutline = width
        }
        guard shown != outlineShown else {
            applyOutlineWidthIfNeeded()
            placeDividers()
            return
        }
        outlineShown = shown
        XYZDiagnostics.note("outline shown=\(shown)")
        if shown {
            rebuild()
            let open = max(160, bounds.width - savedOutline)
            slideDivider(outlineDividerIndex(), to: bounds.width)
            slideDivider(outlineDividerIndex(), to: open, animated: true)
        } else {
            slideDivider(outlineDividerIndex(), to: bounds.width, animated: true) { [weak self] in
                self?.rebuild()
                self?.placeDividers()
            }
        }
    }

    private func outlineDividerIndex() -> Int {
        max(0, panes.subviews.count - 2)
    }

    /// Moves one divider. `animated` eases the width the way VS Code does, without taking focus.
    private func slideDivider(_ index: Int, to target: CGFloat, animated: Bool = false, completion: (() -> Void)? = nil) {
        chromeTimer?.invalidate()
        chromeTimer = nil
        guard panes.subviews.indices.contains(index) else {
            completion?()
            return
        }
        let start = panes.subviews[index].frame.maxX
        if !animated || abs(start - target) < 1 {
            chromeAnimating = true
            panes.setPosition(target, ofDividerAt: index)
            chromeAnimating = false
            placeDividers()
            completion?()
            return
        }
        let began = Date()
        chromeAnimating = true
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let t = min(1, Date().timeIntervalSince(began) / 0.16)
            let eased = 1 - (1 - t) * (1 - t)
            self.panes.setPosition(start + (target - start) * eased, ofDividerAt: index)
            self.placeDividers()
            if t >= 1 {
                timer.invalidate()
                self.chromeTimer = nil
                self.chromeAnimating = false
                completion?()
            }
        }
        chromeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func rebuild() {
        sidebar?.removeFromSuperview()
        detail?.removeFromSuperview()
        outline?.removeFromSuperview()
        if sidebarShown, let sidebar {
            panes.addSubview(sidebar)
        }
        if let detail {
            panes.addSubview(detail)
        }
        if outlineShown, let outline {
            panes.addSubview(outline)
        }
        placeDividers()
    }

    private func applyPositions() {
        guard bounds.width > 1 else { return }
        if sidebarShown, panes.subviews.count > 1, panes.subviews[0] === sidebar {
            let room = bounds.width - (outlineShown ? savedOutline : 0) - 480
            let position = min(max(savedPosition, 220), max(220, room))
            panes.setPosition(position, ofDividerAt: 0)
        }
        applyOutlineWidthIfNeeded()
        placeDividers()
    }

    private func applyOutlineWidthIfNeeded() {
        guard !chromeAnimating, outlineShown, let outline, outline.superview != nil, bounds.width > 1 else { return }
        let index = panes.subviews.count - 2
        guard index >= 0 else { return }
        let target = bounds.width - savedOutline
        if abs(outline.frame.width - savedOutline) > 2 {
            panes.setPosition(target, ofDividerAt: index)
        }
    }

    private func moveDivider(_ edge: SidebarDivider.Edge, to position: CGFloat) {
        let index: Int
        switch edge {
        case .left:
            guard sidebarShown, panes.subviews.count > 1 else { return }
            index = 0
        case .right:
            guard outlineShown else { return }
            index = panes.subviews.count - 2
            guard index >= 0 else { return }
        }
        let lower = splitView(panes, constrainMinCoordinate: position, ofSubviewAt: index)
        let upper = splitView(panes, constrainMaxCoordinate: position, ofSubviewAt: index)
        let clamped = min(max(position, lower), max(lower, upper))
        adjusting = true
        panes.setPosition(clamped, ofDividerAt: index)
        adjusting = false
        sidebar?.layoutSubtreeIfNeeded()
        detail?.layoutSubtreeIfNeeded()
        outline?.layoutSubtreeIfNeeded()
        placeDividers()
    }

    private func placeDividers() {
        let children = panes.subviews
        if sidebarShown, children.count > 1, children[0] === sidebar {
            let boundary = panes.convert(NSPoint(x: children[0].frame.maxX, y: 0), to: self).x
            place(leftDivider, at: boundary)
            leftDivider.isHidden = false
        } else if !leftDivider.isHidden {
            leftDivider.isHidden = true
            window?.invalidateCursorRects(for: leftDivider)
        }
        if outlineShown, children.count > 1 {
            let index = children.count - 2
            let boundary = panes.convert(NSPoint(x: children[index].frame.maxX, y: 0), to: self).x
            place(rightDivider, at: boundary)
            rightDivider.isHidden = false
        } else if !rightDivider.isHidden {
            rightDivider.isHidden = true
            window?.invalidateCursorRects(for: rightDivider)
        }
        bringDividersToFront()
    }

    private func place(_ divider: SidebarDivider, at boundary: CGFloat) {
        let width = SidebarDivider.hitWidth
        let frame = NSRect(x: boundary - width / 2, y: 0, width: width, height: bounds.height)
        let same = abs(divider.frame.origin.x - frame.origin.x) < 0.5
            && abs(divider.frame.size.height - frame.size.height) < 0.5
            && abs(divider.frame.size.width - frame.size.width) < 0.5
        if !same {
            divider.frame = frame
            window?.invalidateCursorRects(for: divider)
        }
    }

    private func bringDividersToFront() {
        let front = subviews.suffix(2)
        let already = front.contains(where: { $0 === leftDivider }) && front.contains(where: { $0 === rightDivider })
        if already { return }
        addSubview(leftDivider)
        addSubview(rightDivider)
    }

    private func invalidateDividerCursors() {
        guard let window else { return }
        window.invalidateCursorRects(for: leftDivider)
        window.invalidateCursorRects(for: rightDivider)
    }

    private func isRightDivider(_ dividerIndex: Int, in splitView: NSSplitView) -> Bool {
        outlineShown && dividerIndex == splitView.subviews.count - 2
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if chromeAnimating { return 0 }
        if isRightDivider(dividerIndex, in: splitView) {
            return sidebarShown ? 220 + 480 : 480
        }
        return 220
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if chromeAnimating { return splitView.bounds.width }
        if isRightDivider(dividerIndex, in: splitView) {
            return max(480, splitView.bounds.width - 160)
        }
        let reserve: CGFloat = outlineShown ? 160 : 0
        return max(220, splitView.bounds.width - 480 - reserve)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let lower = self.splitView(splitView, constrainMinCoordinate: proposedPosition, ofSubviewAt: dividerIndex)
        let upper = self.splitView(splitView, constrainMaxCoordinate: proposedPosition, ofSubviewAt: dividerIndex)
        return min(max(proposedPosition, lower), max(lower, upper))
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        sidebar?.needsLayout = true
        detail?.needsLayout = true
        outline?.needsLayout = true
        if !chromeAnimating, outlineShown, let outline, outline.superview != nil {
            let width = outline.frame.width
            if abs(width - savedOutline) > 0.5 {
                savedOutline = width
                onOutlineWidth?(width)
            }
        }
        if !chromeAnimating, sidebarShown, let sidebar, sidebar.superview != nil {
            savedPosition = sidebar.frame.width
        }
    }
}

/// No system divider. The overlay views draw and drag the edges.
private final class PaneSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}
    override func resetCursorRects() {}
}

private enum SidebarDividerColor {
    static func separator(for appearance: NSAppearance) -> NSColor {
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 43 / 255, green: 43 / 255, blue: 43 / 255, alpha: 1)
        }
        return NSColor(srgbRed: 229 / 255, green: 229 / 255, blue: 229 / 255, alpha: 1)
    }

    /// VS Code `focusBorder` (#007FD4).
    static let accent = NSColor(srgbRed: 0, green: 127 / 255, blue: 212 / 255, alpha: 1)
}

/// A 5pt grab strip. The resting mark is one pixel. Hover and drag thicken it in the sash blue.
private final class SidebarDivider: NSView {
    enum Edge: String { case left, right }
    static let hitWidth: CGFloat = 5

    let edge: Edge
    var boundaryX: () -> CGFloat = { 0 }
    var moveTo: (CGFloat) -> Void = { _ in }

    private let hairline = CALayer()
    private let accent = CALayer()
    private var tracking: NSTrackingArea?
    private var inside = false
    private var dragging = false
    private var highlighted = false
    private var hoverToken = 0
    private var lastCursorLog = Date.distantPast

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        accent.opacity = 0
        layer?.addSublayer(hairline)
        layer?.addSublayer(accent)
        setAccessibilityIdentifier("xyz.divider.\(edge.rawValue)")
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let hair = 1 / scale
        let mid = (bounds.midX * scale).rounded() / scale
        hairline.frame = CGRect(x: mid - hair / 2, y: 0, width: hair, height: bounds.height)
        let thick: CGFloat = 3
        accent.frame = CGRect(x: bounds.midX - thick / 2, y: 0, width: thick, height: bounds.height)
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        let now = Date()
        if now.timeIntervalSince(lastCursorLog) > 0.4 {
            lastCursorLog = now
            XYZDiagnostics.note("divider cursorUpdate edge=\(edge.rawValue)")
        }
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        inside = true
        XYZDiagnostics.note("divider enter edge=\(edge.rawValue)")
        scheduleHover()
    }

    override func mouseExited(with event: NSEvent) {
        inside = false
        hoverToken += 1
        XYZDiagnostics.note("divider exit edge=\(edge.rawValue)")
        if !dragging {
            setHighlight(on: false, reason: "exit")
        }
    }

    override func mouseDown(with event: NSEvent) {
        hoverToken += 1
        dragging = true
        setHighlight(on: true, reason: "drag")
        NSCursor.resizeLeftRight.set()
        let startX = event.locationInWindow.x
        let start = boundaryX()
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            NSCursor.resizeLeftRight.set()
            moveTo(start + (next.locationInWindow.x - startX))
            if next.type == .leftMouseUp { break }
        }
        dragging = false
        setHighlight(on: false, reason: "dragEnd")
        if inside {
            scheduleHover()
        }
    }

    private func scheduleHover() {
        hoverToken += 1
        let token = hoverToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.hoverToken == token, self.inside, !self.dragging else { return }
            self.setHighlight(on: true, reason: "hover")
        }
    }

    private func setHighlight(on: Bool, reason: String) {
        guard on != highlighted else { return }
        highlighted = on
        XYZDiagnostics.note("divider highlight edge=\(edge.rawValue) on=\(on) reason=\(reason)")
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        accent.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    private func updateColors() {
        hairline.backgroundColor = SidebarDividerColor.separator(for: effectiveAppearance).cgColor
        accent.backgroundColor = SidebarDividerColor.accent.cgColor
    }
}

struct WorkspaceView: View {
    @ObservedObject var session: WorkspaceSession
    @Environment(\.undoManager) private var undoManager
    @StateObject private var commands = WorkspaceCommandBridge()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var titlebarInset: CGFloat = 0
    @AppStorage(XYZEditorStyle.wordWrapKey) private var wordWrap = true
    @StateObject private var outline = OutlineModel()
    @AppStorage(HiddenFilesSetting.key) private var storedHiddenFiles = true

    var body: some View {
        VStack(spacing: 0) {
            // A top padding on the full-height host pushes the editor past the window.
            // This row is the title-bar overlap, so the status bar stays inside the frame.
            Color.clear.frame(height: titlebarInset)
            WorkspaceSplit(
                showsSidebar: columnVisibility != .detailOnly,
                showsOutline: showsMarkdownOutline,
                outlineWidth: session.outlineWidth,
                onOutlineWidth: { session.rememberOutlineWidth($0) }
            ) {
                WorkspaceSidebar(session: session, undoManager: undoManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.sidebarBackground)
            } detail: {
                WorkspaceDetail(
                    session: session,
                    outline: outline,
                    find: commands.findModel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.editorBackground)
            } outline: {
                OutlineSidebar(session: session, outline: outline)
            }
            if session.buffer != nil {
                EditorStatusBar(
                    caret: statusEditing ? session.caret : nil,
                    encodingValue: showsStatusText ? session.buffer?.encoding : nil,
                    lineEndingValue: showsStatusText ? session.buffer?.lineEnding : nil,
                    mixedEndings: session.buffer?.mixedLineEndings == true,
                    typeName: statusMode,
                    words: nil,
                    showsReadingTime: false,
                    detail: nil,
                    showsWrap: statusEditing && wordWrap,
                    onEncoding: encodingChange,
                    onLineEnding: endingChange
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .frame(minWidth: 880, minHeight: 520)
        .background(Color.editorBackground)
        .background(WorkspaceWindowChrome(
            title: titleText,
            representedFile: session.buffer?.url,
            sidebarShown: columnVisibility != .detailOnly,
            outlineShown: showsMarkdownOutline,
            outlineEnabled: outlineToggleEnabled,
            titlebarInset: $titlebarInset,
            onToggleSidebar: {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            },
            onToggleOutline: { session.toggleOutlinePane() }
        ))
        .background(
            EditorCommandAnchor(target: commands) {
                commands.attach(session: session, columnVisibility: $columnVisibility)
            }
        )
        .workspaceFolderDrop()
        .onChange(of: storedHiddenFiles) { _, value in
            if session.showsHiddenFiles != value {
                session.showsHiddenFiles = value
            }
        }
        .onAppear { refreshMarkdownOutline() }
        .onChange(of: session.buffer?.editorToken) { _, _ in
            refreshMarkdownOutline()
        }
        .focusedSceneValue(
            \.workspaceActions,
            WorkspaceActions(
                showsHidden: session.showsHiddenFiles,
                toggleHidden: { session.showsHiddenFiles.toggle() },
                focusSearch: { EditorCommands.shared.focusFilter(nil) }
            )
        )
    }

    private var encodingChange: ((TextEncoding) -> Void)? {
        guard statusEditing else { return nil }
        return { session.chooseEncoding($0) }
    }

    private var endingChange: ((LineEnding) -> Void)? {
        guard statusEditing else { return nil }
        return { session.chooseLineEnding($0) }
    }

    private var showsStatusText: Bool {
        guard let kind = session.buffer?.kind else { return false }
        return kind == .markdown || kind == .plainText || kind == .readOnly
    }

    private var statusEditing: Bool {
        guard let buffer = session.buffer else { return false }
        return EditorModeChoice.isEditing(session.viewMode, access: WorkspaceSession.access(of: buffer))
    }

    private var statusMode: String {
        guard let buffer = session.buffer else { return "" }
        let format = FileFormats.format(for: buffer.relativePath)
        let access = WorkspaceSession.access(of: buffer)
        if access == .locked {
            return buffer.kind == .readOnly ? "Read-only" : format.label
        }
        return statusEditing ? "Editing" : "Read-only"
    }

    private var titleText: String {
        let folder = session.displayName
        guard let path = openFilePath else { return folder }
        let file = (path as NSString).lastPathComponent
        return "\(file) — \(folder)"
    }

    private var outlineToggleEnabled: Bool {
        guard let path = session.buffer?.relativePath else { return false }
        return FileFormats.format(for: path).language == .markdown
    }

    /// The right outline is only for a Markdown file, and only when this window left it open.
    private var showsMarkdownOutline: Bool {
        guard session.outlineVisible, let path = session.buffer?.relativePath else { return false }
        return FileFormats.format(for: path).language == .markdown
    }

    private func refreshMarkdownOutline() {
        guard let text = session.buffer?.text,
              FileFormats.format(for: session.buffer?.relativePath ?? "").language == .markdown else {
            outline.clear()
            return
        }
        outline.update(text: text, language: .markdown)
    }

    private var openFilePath: String? {
        if let path = session.selectedPath, let node = session.node(at: path), !node.isDirectory {
            return node.relativePath
        }
        return session.buffer?.relativePath
    }
}

/// The window title is `<file> — <folder>`. The proxy icon is that file.
private struct WorkspaceWindowChrome: NSViewRepresentable {
    var title: String
    var representedFile: URL?
    var sidebarShown: Bool
    var outlineShown: Bool
    var outlineEnabled: Bool
    @Binding var titlebarInset: CGFloat
    var onToggleSidebar: () -> Void
    var onToggleOutline: () -> Void

    func makeNSView(context: Context) -> WorkspaceChromeView {
        let view = WorkspaceChromeView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: WorkspaceChromeView, context: Context) {
        apply(to: view)
        view.apply()
    }

    private func apply(to view: WorkspaceChromeView) {
        view.title = title
        view.representedFile = representedFile
        view.sidebarShown = sidebarShown
        view.outlineShown = outlineShown
        view.outlineEnabled = outlineEnabled
        view.onToggleSidebar = onToggleSidebar
        view.onToggleOutline = onToggleOutline
        view.onTitlebarInset = { inset in
            if abs(titlebarInset - inset) > 0.5 {
                titlebarInset = inset
            }
        }
    }
}

final class WorkspaceChromeView: NSView {
    var title = ""
    var representedFile: URL?
    var sidebarShown = true
    var outlineShown = false
    var outlineEnabled = false
    var onToggleSidebar: () -> Void = {}
    var onToggleOutline: () -> Void = {}
    var onTitlebarInset: (CGFloat) -> Void = { _ in }
    private let titles = TitlebarTitleInstaller()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func layout() {
        super.layout()
        // SwiftUI can put the title and a toolbar back during layout.
        apply()
    }

    func apply() {
        guard let window else { return }
        WorkspaceChrome.apply(to: window, title: title, subtitle: "", representedFile: representedFile)
        titles.install(in: window, title: title)
        titles.updateToggles(
            sidebarShown: sidebarShown,
            outlineShown: outlineShown,
            outlineEnabled: outlineEnabled,
            onSidebar: onToggleSidebar,
            onOutline: onToggleOutline
        )
        let overlap = titles.overlap(in: window)
        onTitlebarInset(overlap)
    }
}

/// Centered `<file> — <folder>` in the same row as the traffic lights.
///
/// The label does not take clicks, so the title bar still drags and a double click still zooms.
/// An accessory view would add a second row and, on macOS 27, SwiftUI drawn under the title-bar
/// material does not paint. This label is a subview of the title bar, so it does.
final class TitlebarTitleInstaller {
    private let label = TitlebarTitleLabel(labelWithString: "")
    private let toggles = TitlebarLayoutToggles()

    init() {
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("xyz.window.title")
    }

    func install(in window: NSWindow, title: String) {
        guard let close = window.standardWindowButton(.closeButton),
              let bar = close.superview else { return }
        if label.superview !== bar || toggles.superview !== bar {
            NSLayoutConstraint.deactivate(constraints)
            label.removeFromSuperview()
            toggles.removeFromSuperview()
            bar.addSubview(label, positioned: .below, relativeTo: close)
            bar.addSubview(toggles)
            let center = label.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
            center.priority = .defaultHigh
            constraints = [
                center,
                label.centerYAnchor.constraint(equalTo: close.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 78),
                label.trailingAnchor.constraint(lessThanOrEqualTo: toggles.leadingAnchor, constant: -8),
                toggles.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
                toggles.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            ]
            NSLayoutConstraint.activate(constraints)
        }
        if label.stringValue != title {
            label.stringValue = title
        }
        let accessories = window.titlebarAccessoryViewControllers
        let kept = accessories.filter { $0.identifier?.rawValue != "xyz.titlebar.tabs" }
        if kept.count != accessories.count {
            window.titlebarAccessoryViewControllers = kept
        }
    }

    func updateToggles(
        sidebarShown: Bool,
        outlineShown: Bool,
        outlineEnabled: Bool,
        onSidebar: @escaping () -> Void,
        onOutline: @escaping () -> Void
    ) {
        toggles.update(
            sidebarShown: sidebarShown,
            outlineShown: outlineShown,
            outlineEnabled: outlineEnabled,
            onSidebar: onSidebar,
            onOutline: onOutline
        )
    }

    /// How far the content view extends up into the title-bar row.
    /// Zero when the content already starts below the traffic lights.
    func overlap(in window: NSWindow) -> CGFloat {
        guard let content = window.contentView,
              let close = window.standardWindowButton(.closeButton) else { return 0 }
        let frame = content.convert(close.bounds, from: close)
        let top: CGFloat
        let bottom: CGFloat
        if content.isFlipped {
            top = frame.minY
            bottom = frame.maxY
        } else {
            top = content.bounds.height - frame.maxY
            bottom = content.bounds.height - frame.minY
        }
        let barHeight = close.superview?.bounds.height ?? 0
        if barHeight >= 20, barHeight <= 44 {
            return barHeight
        }
        if top > 40 { return 28 }
        let inset = bottom + 8
        if inset <= 0 { return 28 }
        return min(max(inset, 20), 40)
    }

    private var constraints: [NSLayoutConstraint] = []
}

/// Clicks pass through to the title bar, which drags the window and zooms on a double click.
final class TitlebarTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// Left sidebar, then outline, at the trailing end of the title-bar row.
final class TitlebarLayoutToggles: NSView {
    private let left = TitlebarToggleButton(side: .left)
    private let right = TitlebarToggleButton(side: .right)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        left.toolTip = String(localized: "Toggle Left Sidebar (⌘B)")
        right.toolTip = String(localized: "Toggle Outline (⌥⌘B)")
        left.setAccessibilityLabel(left.toolTip)
        right.setAccessibilityLabel(right.toolTip)
        addSubview(left)
        addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 22),
            left.heightAnchor.constraint(equalToConstant: 22),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 2),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.centerYAnchor.constraint(equalTo: left.centerYAnchor),
            right.widthAnchor.constraint(equalToConstant: 22),
            right.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(
        sidebarShown: Bool,
        outlineShown: Bool,
        outlineEnabled: Bool,
        onSidebar: @escaping () -> Void,
        onOutline: @escaping () -> Void
    ) {
        left.filled = sidebarShown
        left.onClick = onSidebar
        right.filled = outlineShown
        right.isToggleEnabled = outlineEnabled
        right.onClick = onOutline
        left.needsDisplay = true
        right.needsDisplay = true
    }
}

/// Borderless title-bar icon. A filled pane means that sidebar is open.
final class TitlebarToggleButton: NSView {
    enum Side { case left, right }

    var side: Side = .left
    var filled = true
    var isToggleEnabled = true
    var onClick: () -> Void = {}

    private var hovered = false
    private var tracking: NSTrackingArea?

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let wasKey = window?.isKeyWindow == true
        let responder = window?.firstResponder
        guard let window else { return }
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if isToggleEnabled {
                hovered = inside
                needsDisplay = true
            }
            if next.type == .leftMouseUp { break }
        }
        hovered = false
        needsDisplay = true
        if inside, isToggleEnabled {
            onClick()
        }
        if wasKey, let responder, window.firstResponder !== responder {
            window.makeFirstResponder(responder)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        if !isToggleEnabled {
            color = .secondaryLabelColor.withAlphaComponent(0.35)
        } else if hovered {
            color = .secondaryLabelColor.blended(withFraction: 0.55, of: .labelColor) ?? .labelColor
        } else {
            color = .secondaryLabelColor
        }
        color.set()
        let icon = NSRect(x: bounds.midX - 7, y: bounds.midY - 5, width: 14, height: 10)
        let outer = NSBezierPath(roundedRect: icon, xRadius: 2, yRadius: 2)
        let paneWidth: CGFloat = 4.5
        let paneX = side == .left ? icon.minX : icon.maxX - paneWidth
        let pane = NSRect(x: paneX, y: icon.minY, width: paneWidth, height: icon.height)
        if filled {
            NSGraphicsContext.current?.saveGraphicsState()
            outer.addClip()
            pane.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        outer.lineWidth = 1
        outer.stroke()
        let dividerX = side == .left ? icon.minX + paneWidth : icon.maxX - paneWidth
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: icon.minY + 1))
        divider.line(to: NSPoint(x: dividerX, y: icon.maxY - 1))
        divider.lineWidth = 1
        divider.stroke()
    }
}

enum WorkspaceChrome {
    static func apply(to window: NSWindow, title: String, subtitle: String, representedFile: URL?) {
        _ = subtitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.showsBaselineSeparator = false
        // A toolbar draws over the title and adds its own buttons. This window has neither.
        if window.toolbar != nil {
            window.toolbar = nil
        }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.backgroundColor = .textBackgroundColor
        if window.title != title {
            window.title = title
        }
        if !window.subtitle.isEmpty {
            window.subtitle = ""
        }
        if window.representedURL != representedFile {
            window.representedURL = representedFile
        }
    }
}

private struct WorkspaceDetail: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var outline: OutlineModel
    var find: EditorFindModel?
    @Environment(\.undoManager) private var undoManager
    @AppStorage(WordCountSetting.key) private var showsWordCount = false
    @StateObject private var wordCount = WordCountModel()
    @State private var caret = EditorCaret()
    @State private var surfaceDetail: String?
    @AppStorage(XYZEditorStyle.readingLineNumbersKey) private var readingLineNumbers = false

    var body: some View {
        VStack(spacing: 0) {
            if session.buffer != nil {
                EditorTabBar(session: session)
                if let path = activePath {
                    EditorBreadcrumb(
                        rootName: session.displayName,
                        relativePath: path,
                        siblings: { session.siblingNodes(of: $0) }
                    ) { crumb in
                        session.revealCrumb(crumb)
                    }
                }
            }
            if let status = banner {
                bannerView(status)
            }
            fileBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preference(key: EditorStatusKey.self, value: statusSnapshot)
        .background(Color.editorBackground)
        .overlay(alignment: .top) {
            if let find {
                FindBarHost(model: find)
            }
        }
        .overlay(alignment: .top) {
            if let picker = session.tabSwitch {
                TabSwitchPicker(paths: picker.paths, index: picker.index) { index in
                    session.moveTabSwitch(index - picker.index)
                    session.commitTabSwitch()
                }
                .padding(.top, 36)
            }
        }
        .onAppear {
            countWords(immediate: true)
            refreshOutline(immediate: true)
        }
        .onChange(of: session.buffer?.editorToken) { _, _ in
            session.previewBridge.send(session.buffer?.text ?? "")
            caret = EditorCaret()
            session.caret = EditorCaret()
            session.clearViewportLine()
            surfaceDetail = nil
            countWords(immediate: true)
            refreshOutline(immediate: true)
        }
        .onChange(of: showsWordCount) { _, _ in
            countWords(immediate: true)
        }
        .onChange(of: session.viewMode) { _, mode in
            if mode == .reading {
                find?.showsReplace = false
            }
        }
    }

    @ViewBuilder
    private var fileBody: some View {
        if session.buffer == nil {
            ContentUnavailableView {
                Label("No File Open", systemImage: "doc.text")
            } description: {
                Text("Choose a file in the sidebar.\n⌘P opens one. ⌘K searches the folder.")
            }
        } else if showsPreview {
            reading
        } else if showsEditor {
            editor
        } else if let buffer = session.buffer, buffer.kind == .tooLarge {
            placeholder(for: buffer)
                .background(Color.editorBackground)
        } else if let buffer = session.buffer {
            FileSurface(url: buffer.url, viewer: format.viewer, onDetail: { surfaceDetail = $0 })
                .id(buffer.editorToken)
                .background(Color.editorBackground)
        }
    }

    private var statusSnapshot: EditorStatusSnapshot {
        guard session.buffer != nil else { return .empty }
        let caretValue: EditorCaret? = isEditing ? caret : nil
        let encoding: TextEncoding? = showsText ? session.buffer?.encoding : nil
        let ending: LineEnding? = showsText ? session.buffer?.lineEnding : nil
        let words: TextStatistics? = (format.isProse && !isReadOnly) ? wordCount.stats : nil
        let detailText: String?
        if isReadOnly && session.buffer?.previewTruncated == true {
            detailText = String(localized: "Preview truncated")
        } else if showsText {
            detailText = nil
        } else {
            detailText = surfaceDetail
        }
        return EditorStatusSnapshot(
            visible: true,
            caret: caretValue,
            encoding: encoding,
            lineEnding: ending,
            mixedEndings: session.buffer?.mixedLineEndings == true,
            typeName: statusMode,
            words: words,
            showsReadingTime: showsWordCount && format.isProse && !isReadOnly,
            detail: detailText,
            canEditEncoding: isEditing,
            canEditEnding: isEditing
        )
    }

    private func refreshOutline(immediate: Bool) {
        guard format.language == .markdown, let text = session.buffer?.text else {
            outline.clear()
            return
        }
        outline.update(text: text, language: .markdown)
        _ = immediate
    }

    private var activePath: String? {
        session.buffer?.relativePath ?? session.tabStrip.activeID
    }

    private var format: FileFormat {
        FileFormats.format(for: session.buffer?.relativePath ?? activePath ?? "")
    }

    private var showsText: Bool {
        guard let kind = session.buffer?.kind else { return false }
        return kind == .markdown || kind == .plainText || kind == .readOnly
    }

    private var editableText: Bool {
        guard let kind = session.buffer?.kind else { return false }
        return kind == .markdown || kind == .plainText
    }

    private var isReadOnly: Bool { session.buffer?.kind == .readOnly }

    private var statusMode: String {
        if fileAccess == .locked {
            return isReadOnly ? "Read-only" : format.label
        }
        return isEditing ? "Editing" : "Read-only"
    }

    private func countWords(immediate: Bool) {
        guard format.isProse, let text = session.buffer?.text else { return }
        wordCount.update(text, immediate: immediate)
    }

    private var fileAccess: EditorFileAccess {
        guard let buffer = session.buffer else { return .locked }
        return WorkspaceSession.access(of: buffer)
    }

    private var showsEditor: Bool { showsText && !showsPreview }

    private var showsPreview: Bool {
        EditorModeChoice.showsRenderedPreview(mode: session.viewMode, access: fileAccess)
    }

    private var isEditing: Bool {
        EditorModeChoice.isEditing(session.viewMode, access: fileAccess)
    }

    private var showsEditorLineNumbers: Bool {
        EditorModeChoice.showsLineNumbers(
            mode: session.viewMode,
            access: fileAccess,
            readingNumbers: readingLineNumbers
        )
    }

    @ViewBuilder
    private var reading: some View {
        preview
    }

    private func placeholder(for buffer: WorkspaceFileBuffer) -> some View {
        ContentUnavailableView {
            Label("File Too Large", systemImage: "doc")
        } description: {
            Text("This file is too large to edit in XYZ.")
        } actions: {
            Button("Open with Default App") {
                NSWorkspace.shared.open(buffer.url)
            }
        }
    }

    private var banner: String? {
        guard let buffer = session.buffer else { return nil }
        if buffer.isMissing {
            return String(localized: "This file was removed from the folder.")
        }
        if buffer.conflictText != nil {
            return String(localized: "This file changed on disk.")
        }
        return buffer.status
    }

    private func bannerView(_ message: String) -> some View {
        let buffer = session.buffer
        return HStack(spacing: 12) {
            Text(message)
            Spacer(minLength: 8)
            if buffer?.conflictText != nil {
                Button("Reload") { buffer?.reloadFromDisk() }
                Button("Overwrite") { buffer?.overwrite() }
            } else if buffer?.isMissing == true && buffer?.kind != .binary && buffer?.kind != .tooLarge {
                Button("Save Anyway") { buffer?.overwrite() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.18))
    }

    private var preview: some View {
        MarkdownPreview(
            bridge: session.previewBridge,
            host: session.previewHost,
            scrollLink: session.scrollLink,
            baseDirectory: session.buffer?.url.deletingLastPathComponent()
        )
    }

    private var editor: some View {
        XYZEditor(
            text: session.buffer?.text ?? "",
            isEditable: isEditing,
            undoManager: undoManager,
            reloadToken: session.buffer?.editorToken ?? 0,
            scrollLink: session.scrollLink,
            markup: format.language == .markdown,
            spellCheck: format.isProse,
            syntax: format.language,
            forcesMonospace: format.usesCodeFont,
            onSelection: {
                caret = $0
                session.caret = $0
            },
            onTextChange: { newText in
                session.buffer?.userEdited(newText)
                session.previewBridge.send(newText)
                if format.isProse {
                    wordCount.update(newText)
                }
                if format.language == .markdown {
                    outline.update(text: newText, language: .markdown)
                }
            },
            lineNumbersVisible: showsEditorLineNumbers,
            find: find
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Forwards View-menu and palette actions to the open folder.
@MainActor
final class WorkspaceCommandBridge: ObservableObject, EditorCommandTarget {
    private let storedFind = EditorFindModel()
    var findModel: EditorFindModel? { storedFind }
    private weak var session: WorkspaceSession?
    private var columnVisibility: Binding<NavigationSplitViewVisibility> = .constant(.all)

    func attach(session: WorkspaceSession, columnVisibility: Binding<NavigationSplitViewVisibility>) {
        self.session = session
        self.columnVisibility = columnVisibility
        if EditorCommands.shared.target === self {
            EditorCommandState.shared.setOpenFile(session.buffer != nil)
        }
    }

    var editorHasOpenFile: Bool { session?.buffer != nil }

    var editorViewMode: EditorViewMode { session?.viewMode ?? .reading }
    var editorCanToggle: Bool {
        guard let buffer = session?.buffer else { return false }
        return EditorModeChoice.canToggle(WorkspaceSession.access(of: buffer))
    }
    var editorIsEditing: Bool {
        guard let session, let buffer = session.buffer else { return false }
        return EditorModeChoice.isEditing(session.viewMode, access: WorkspaceSession.access(of: buffer))
    }
    var editorShowsRenderedReading: Bool {
        guard let session, let buffer = session.buffer else { return false }
        return EditorModeChoice.showsRenderedPreview(mode: session.viewMode, access: WorkspaceSession.access(of: buffer))
    }

    func beginEditing(source: String) -> Bool {
        session?.beginEditing(source: source) ?? false
    }
    var showsHiddenFiles: Bool { session?.showsHiddenFiles ?? true }
    var supportsWorkspaceFiles: Bool { session != nil }

    func editorSelect(_ mode: EditorViewMode, source: String) {
        session?.selectViewMode(mode, source: source)
        if mode == .reading {
            storedFind.showsReplace = false
        }
    }

    func editorToggle(source: String) {
        session?.toggleViewMode(source: source)
    }

    func paletteFiles() -> [PaletteFile] {
        session?.paletteFiles() ?? []
    }

    func paletteOpen(fileID: String, newWindow: Bool) {
        guard let session else { return }
        if newWindow {
            session.openInDocumentWindow(relativePath: fileID)
        } else {
            session.openRelative(fileID)
        }
    }

    func toggleSidebar() {
        columnVisibility.wrappedValue = columnVisibility.wrappedValue == .detailOnly ? .all : .detailOnly
    }

    var showsOutlinePane: Bool { session?.outlineVisible ?? false }

    func toggleOutlinePane() {
        session?.toggleOutlinePane()
    }

    func focusFilter() {
        guard let session else { return }
        EditorCommands.shared.toggleGlobalSearch(session)
    }

    func replaceInFolder(pattern: String, replacement: String) {
        session?.replaceInFolder(pattern: pattern, replacement: replacement, undoManager: NSApp.keyWindow?.undoManager)
    }

    func toggleHiddenFiles() {
        session?.showsHiddenFiles.toggle()
    }

    func newFile() {
        session?.newItem(directory: false)
    }

    func newFolder() {
        session?.newItem(directory: true)
    }

    func reveal() {
        session?.revealOpenItem()
    }

    func copyPath() {
        session?.copyOpenPath()
    }

    func copyRelativePath() {
        session?.copyRelativePath()
    }

    func closeActiveTab() -> Bool {
        session?.closeActiveTab() ?? false
    }

    func selectTab(number: Int) -> Bool {
        session?.selectTab(number: number) ?? false
    }

    func reloadFile() {
        session?.reloadOpenFile()
    }

    func paletteHeadings() -> [OutlineHeading] {
        guard let buffer = session?.buffer, buffer.kind == .markdown else { return [] }
        return MarkdownOutline.headings(in: buffer.text)
    }

    func revealHeading(line: Int) {
        session?.scrollLink.revealLine(line)
    }

    func reopenClosedTab() -> Bool {
        session?.reopenClosedTab() ?? false
    }

    func revealActiveFile() {
        session?.revealActiveFile()
    }

    func revealPosition(line: Int, column: Int) {
        session?.revealPosition(line: line, column: column)
    }

    func beginTabSwitch() -> Bool {
        session?.beginTabSwitch() ?? false
    }

    func moveTabSwitch(_ delta: Int) {
        session?.moveTabSwitch(delta)
    }

    func commitTabSwitch() {
        session?.commitTabSwitch()
    }

    func cancelTabSwitch() {
        session?.cancelTabSwitch()
    }

    var isSwitchingTabs: Bool { session?.tabSwitch != nil }
}

extension View {
    func workspaceFolderDrop() -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            WorkspaceFolderDrop.handle(providers)
        }
    }
}
#endif
