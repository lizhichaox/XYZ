#if os(macOS)
import AppKit
import QuartzCore
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
    var sidebarVisibility: SidebarVisibility
    var showsOutline: Bool
    var sidebarWidth: CGFloat
    var sidebarWidthAdjusted: Bool
    var outlineWidth: CGFloat
    var outlineWidthAdjusted: Bool
    var onOutlineWidth: (CGFloat) -> Void
    var onSidebarWidth: (CGFloat) -> Void
    var sidebarContentWidth: () -> CGFloat
    var outlineContentWidth: () -> CGFloat
    var sidebar: Sidebar
    var detail: Detail
    var outline: Outline

    init(
        showsSidebar: Bool,
        sidebarVisibility: SidebarVisibility,
        showsOutline: Bool,
        sidebarWidth: CGFloat,
        sidebarWidthAdjusted: Bool,
        outlineWidth: CGFloat,
        outlineWidthAdjusted: Bool,
        onOutlineWidth: @escaping (CGFloat) -> Void,
        onSidebarWidth: @escaping (CGFloat) -> Void,
        sidebarContentWidth: @escaping () -> CGFloat,
        outlineContentWidth: @escaping () -> CGFloat,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder outline: () -> Outline
    ) {
        self.showsSidebar = showsSidebar
        self.sidebarVisibility = sidebarVisibility
        self.showsOutline = showsOutline
        self.sidebarWidth = sidebarWidth
        self.sidebarWidthAdjusted = sidebarWidthAdjusted
        self.outlineWidth = outlineWidth
        self.outlineWidthAdjusted = outlineWidthAdjusted
        self.onOutlineWidth = onOutlineWidth
        self.onSidebarWidth = onSidebarWidth
        self.sidebarContentWidth = sidebarContentWidth
        self.outlineContentWidth = outlineContentWidth
        self.sidebar = sidebar()
        self.detail = detail()
        self.outline = outline()
    }

    func makeNSView(context: Context) -> XYZSplitView {
        let split = XYZSplitView()
        let side = PaneHost(rootView: sidebar)
        let main = PaneHost(rootView: detail)
        let outlineHost = PaneHost(rootView: outline)
        side.sizingOptions = []
        main.sizingOptions = []
        outlineHost.sizingOptions = []
        for host in [side as NSView, main as NSView, outlineHost as NSView] {
            host.wantsLayer = true
            host.layer?.masksToBounds = true
        }
        context.coordinator.side = side
        context.coordinator.detail = main
        context.coordinator.outline = outlineHost
        split.onOutlineWidth = onOutlineWidth
        split.onSidebarWidth = onSidebarWidth
        split.measureSidebar = sidebarContentWidth
        split.measureOutline = outlineContentWidth
        split.install(
            sidebar: side,
            detail: main,
            outline: outlineHost,
            showsSidebar: showsSidebar,
            showsOutline: showsOutline
        )
        split.applyPreferences(
            sidebar: sidebarWidth,
            sidebarAdjusted: sidebarWidthAdjusted,
            outline: outlineWidth,
            outlineAdjusted: outlineWidthAdjusted
        )
        sidebarVisibility.attach(split: split)
        return split
    }

    func updateNSView(_ split: XYZSplitView, context: Context) {
        context.coordinator.side?.rootView = sidebar
        context.coordinator.detail?.rootView = detail
        context.coordinator.outline?.rootView = outline
        split.onOutlineWidth = onOutlineWidth
        split.onSidebarWidth = onSidebarWidth
        split.measureSidebar = sidebarContentWidth
        split.measureOutline = outlineContentWidth
        split.applyPreferences(
            sidebar: sidebarWidth,
            sidebarAdjusted: sidebarWidthAdjusted,
            outline: outlineWidth,
            outlineAdjusted: outlineWidthAdjusted
        )
        split.setOutline(shown: showsOutline)
        // The sidebar is not pushed from here: the split view owns it after install.
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

/// Sidebar visibility, owned by AppKit.
///
/// SwiftUI used to own it in `@State`: every ⌘B re-evaluated the whole window body
/// (editor, preview, outline) and then pushed the value back down through `updateNSView`,
/// which fought the split view's own animation. Here the split view owns the state, the
/// title-bar buttons and the command target talk to it directly, and SwiftUI is not in the
/// loop at all — toggling the sidebar never renders the window body.
@MainActor
final class SidebarVisibility {
    private(set) var shown = true
    private weak var split: XYZSplitView?
    private var observers: [(Bool) -> Void] = []

    func attach(split: XYZSplitView) {
        self.split = split
        split.onSidebarVisibilityChange = { [weak self] shown in
            self?.report(shown)
        }
    }

    func toggle() {
        set(!shown)
    }

    func set(_ value: Bool) {
        guard value != shown else { return }
        shown = value
        split?.setSidebarShown(value)
        notify()
    }

    /// The split view finished or started a change; keep the buttons in step.
    func report(_ value: Bool) {
        guard value != shown else { return }
        shown = value
        notify()
    }

    func observe(_ body: @escaping (Bool) -> Void) {
        observers.append(body)
        body(shown)
    }

    private func notify() {
        for observer in observers { observer(shown) }
    }
}

/// The panes sit in an `NSSplitView` with no divider of its own. The hairlines are separate
/// views in front of the editor, so a web view or text view cannot take the resize cursor.
final class XYZSplitView: NSView, NSSplitViewDelegate {
    fileprivate var sidebar: NSView?
    fileprivate var detail: NSView?
    fileprivate var outline: NSView?

    /// The editor column's current width, for the split-jitter check. This is what the
    /// eye reads as the content area.
    var detailWidth: CGFloat { detail?.frame.width ?? 0 }
    var onOutlineWidth: ((CGFloat) -> Void)?
    var onSidebarWidth: ((CGFloat) -> Void)?
    /// Told when the sidebar should be open, right away, so the title-bar button with the
    /// sidebar glyph follows the click instead of the end of the slide.
    var onSidebarVisibilityChange: ((Bool) -> Void)?
    var measureSidebar: () -> CGFloat = { SidebarFit.sidebarMinimum }
    var measureOutline: () -> CGFloat = { SidebarFit.outlineMinimum }
    private let panes = PaneSplitView()
    private let leftDivider = SidebarDivider(edge: .left)
    private let rightDivider = SidebarDivider(edge: .right)
    private var savedPosition: CGFloat = 260
    private var savedOutline: CGFloat = 220
    private var sidebarShown = true
    private var outlineShown = false
    /// What the last press asked for. `sidebarShown`/`outlineShown` describe which
    /// columns are attached right now, and a hide stays attached until its slide ends.
    private var sidebarWanted = true
    private var outlineWanted = false
    /// False until the user drags the divider; a column that was never sized opens at its
    /// content's width.
    private var sidebarAdjusted = false
    private var outlineAdjusted = false
    private var adjusting = false
    private var dividerDrag = false

    private struct ColumnSlide {
        enum Edge {
            case left
            case right
        }

        var edge: Edge
        var from: CGFloat
        var to: CGFloat
        var started: CFTimeInterval
        var duration: CFTimeInterval

        func width(at time: CFTimeInterval) -> CGFloat {
            let t = min(1, max(0, (time - started) / duration))
            let eased = 1 - pow(1 - t, 3)
            return from + (to - from) * eased
        }
    }

    private var slide: ColumnSlide?
    private var slideTimer: Timer?
    private var lastSidebarPress: CFTimeInterval = 0
    private var lastOutlinePress: CFTimeInterval = 0
    private let rapidPressWindow: CFTimeInterval = 0.18
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        panes.isVertical = true
        panes.dividerStyle = .thin
        panes.delegate = self
        panes.autosaveName = nil
        panes.autoresizingMask = [.width, .height]
        panes.lockFrames = { [weak self] in
            self?.lockColumnFrames()
        }
        panes.wantsLayer = true
        panes.layer?.masksToBounds = true
        addSubview(panes)
        addSubview(leftDivider)
        addSubview(rightDivider)
        leftDivider.boundaryX = { [weak self] in
            self?.sidebar?.frame.maxX ?? 0
        }
        leftDivider.moveTo = { [weak self] position in
            self?.moveDivider(.left, to: position)
        }
        leftDivider.dragEnded = { [weak self] in
            self?.dividerDrag = false
        }
        leftDivider.fitContent = { [weak self] in
            self?.fitToContent(.left)
        }
        rightDivider.boundaryX = { [weak self] in
            self?.detail?.frame.maxX ?? 0
        }
        rightDivider.moveTo = { [weak self] position in
            self?.moveDivider(.right, to: position)
        }
        rightDivider.dragEnded = { [weak self] in
            self?.dividerDrag = false
        }
        rightDivider.fitContent = { [weak self] in
            self?.fitToContent(.right)
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
        enforceColumns()
        adjusting = false
        placeDividers()
    }

    /// The file column stays on screen. The split view was giving the sidebar its ideal
    /// width, which is the whole window, and the note column stayed at zero.
    private func enforceColumns() {
        guard !dividerDrag else { return }
        lockColumnFrames()
    }

    private func lockColumnFrames() {
        let area = panes.bounds
        guard area.width > 1, area.height > 1 else { return }
        let views = panes.subviews
        guard !views.isEmpty else { return }
        let showsSide = views.contains { $0 === sidebar }
        let showsOutline = views.contains { $0 === outline }
        let now = CACurrentMediaTime()
        let side: CGFloat
        if showsSide {
            if let slide, slide.edge == .left {
                side = min(area.width, max(0, slide.width(at: now).rounded()))
            } else {
                side = clampedSidebarWidth()
            }
        } else {
            side = 0
        }
        let outlineWidth: CGFloat
        if showsOutline {
            if let slide, slide.edge == .right {
                outlineWidth = min(area.width - side, max(0, slide.width(at: now).rounded()))
            } else {
                outlineWidth = min(max(160, savedOutline), max(160, area.width - side - 320))
            }
        } else {
            outlineWidth = 0
        }
        let main = max(1, area.width - side - outlineWidth)
        if XYZDiagnostics.enabled, main < 260 || side > area.width * 0.9 || outlineWidth > area.width * 0.9 {
            let subviews = detail?.subviews.map { Int($0.frame.width) } ?? []
            XYZDiagnostics.note("layout area=\(Int(area.width)) side=\(Int(side)) outline=\(Int(outlineWidth)) main=\(Int(main)) sidebarIn=\(showsSide) outlineIn=\(showsOutline) detailSubviews=\(subviews)")
        }
        var x: CGFloat = 0
        for view in views {
            let width: CGFloat
            if view === sidebar {
                width = side
            } else if view === outline {
                width = outlineWidth
            } else {
                width = main
            }
            let span = max(width, 1)
            view.frame = NSRect(x: x, y: 0, width: span, height: area.height)
            x += span
        }
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
        showsOutline: Bool
    ) {
        self.sidebar = sidebar
        self.detail = detail
        self.outline = outline
        sidebarShown = showsSidebar
        outlineShown = showsOutline
        sidebarWanted = showsSidebar
        outlineWanted = showsOutline
        panes.addSubview(detail)
        if !sidebarAdjusted { savedPosition = fitSidebarWidth() }
        if showsOutline, !outlineAdjusted { savedOutline = fitOutlineWidth() }
        syncPanes()
        applyPositions()
    }

    /// Opens or closes the sidebar. A cut, not an ease: the window body is not rendered
    /// by SwiftUI for this, and one layout pass cannot fight a second press.
    func setSidebarShown(_ shown: Bool) {
        guard shown != sidebarWanted else { return }
        let now = CACurrentMediaTime()
        let rapid = now - lastSidebarPress < rapidPressWindow
        lastSidebarPress = now
        sidebarWanted = shown
        onSidebarVisibilityChange?(shown)
        if rapid || slide != nil && abs((slide?.to ?? 0) - (shown ? clampedSidebarWidth() : 0)) < 1 {
            // A burst of presses is a cut, not a tug of war: animating every reversal is
            // what read as shaking. Single presses animate below.
            applySidebar(shown)
            return
        }
        let targetWidth: CGFloat
        if sidebarAdjusted {
            targetWidth = clampedSidebarWidth()
        } else {
            targetWidth = fitSidebarWidth()
            savedPosition = targetWidth
        }
        if shown {
            if !sidebarShown {
                sidebarShown = true
                syncPanes()
                animateColumn(.left, from: 0, to: targetWidth, completion: nil)
            } else {
                animateColumn(.left, from: currentWidth(.left), to: targetWidth, completion: nil)
            }
        } else {
            guard sidebarShown else { return }
            if let sidebar, sidebar.frame.width > 2 {
                savedPosition = max(220, sidebar.frame.width)
            }
            animateColumn(.left, from: currentWidth(.left), to: 0) { [weak self] in
                guard let self else { return }
                self.sidebarShown = false
                self.syncPanes()
                self.applyPositions()
            }
        }
    }

    /// Immediate state change, used for a burst of presses.
    private func applySidebar(_ shown: Bool) {
        slide = nil
        slideTimer?.invalidate()
        slideTimer = nil
        if shown {
            if !sidebarAdjusted { savedPosition = fitSidebarWidth() }
            sidebarShown = true
        } else {
            if let sidebar, sidebar.frame.width > 2 {
                savedPosition = max(220, sidebar.frame.width)
            }
            sidebarShown = false
        }
        syncPanes()
        applyPositions()
        flushPaneLayout(paint: true)
    }

    private func currentWidth(_ edge: ColumnSlide.Edge) -> CGFloat {
        if let slide, slide.edge == edge {
            return max(0, slide.width(at: CACurrentMediaTime()))
        }
        let view = edge == .left ? sidebar : outline
        return max(0, view?.frame.width ?? 0)
    }

    /// Applies the widths the user chose in an earlier session. `adjusted` is false until
    /// they drag a divider, which keeps the opening width content-fitted.
    func applyPreferences(
        sidebar: CGFloat,
        sidebarAdjusted: Bool,
        outline: CGFloat,
        outlineAdjusted: Bool
    ) {
        self.sidebarAdjusted = sidebarAdjusted
        self.outlineAdjusted = outlineAdjusted
        if sidebarAdjusted {
            savedPosition = max(220, sidebar)
        } else if !sidebarShown {
            savedPosition = fitSidebarWidth()
        }
        if outlineAdjusted {
            savedOutline = max(160, outline)
        } else if !outlineShown {
            savedOutline = fitOutlineWidth()
        }
    }

    private func fitSidebarWidth() -> CGFloat {
        SidebarFit.sidebar(
            content: measureSidebar(),
            window: max(bounds.width, 1),
            outline: outlineShown ? savedOutline : 0,
            outlineShown: outlineShown
        )
    }

    private func fitOutlineWidth() -> CGFloat {
        SidebarFit.outline(
            content: measureOutline(),
            window: max(bounds.width, 1),
            sidebar: sidebarShown ? (sidebar?.frame.width ?? savedPosition) : 0,
            sidebarShown: sidebarShown
        )
    }

    /// The outline width the layout would use, for the start of a slide.
    private func targetOutlineWidth() -> CGFloat {
        let area = panes.bounds.width
        guard area > 1 else { return max(160, savedOutline) }
        let side = sidebarShown ? max(0, sidebar?.frame.width ?? clampedSidebarWidth()) : 0
        return min(max(160, savedOutline), max(160, area - side - 320))
    }

    func setOutline(shown: Bool) {
        guard shown != outlineWanted else {
            applyOutlineWidthIfNeeded()
            placeDividers()
            return
        }
        outlineWanted = shown
        let targetWidth: CGFloat
        if outlineAdjusted {
            targetWidth = targetOutlineWidth()
        } else {
            targetWidth = fitOutlineWidth()
            savedOutline = targetWidth
        }
        if shown {
            if !outlineShown {
                outlineShown = true
                syncPanes()
                animateColumn(.right, from: 0, to: targetWidth, completion: nil)
            } else {
                animateColumn(.right, from: currentWidth(.right), to: targetWidth, completion: nil)
            }
        } else {
            guard outlineShown else { return }
            if let outline, outline.frame.width > 2 {
                savedOutline = max(160, outline.frame.width)
            }
            animateColumn(.right, from: currentWidth(.right), to: 0) { [weak self] in
                guard let self else { return }
                self.outlineShown = false
                self.syncPanes()
                self.applyPositions()
            }
        }
    }

    /// Animates one column's width. The split view lays out every 60 Hz tick; no extra
    /// layout pass is forced on top, which is what made the old animation shimmer.
    private func animateColumn(
        _ edge: ColumnSlide.Edge,
        from: CGFloat,
        to: CGFloat,
        completion: (() -> Void)?
    ) {
        slideTimer?.invalidate()
        slideTimer = nil
        let distance = abs(to - from)
        guard distance > 0.5, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            slide = nil
            if edge == .left {
                if to <= 0.5 { sidebarShown = false }
            } else if to <= 0.5 {
                outlineShown = false
            }
            lockColumnFrames()
            placeDividers()
            completion?()
            return
        }
        let duration = min(0.24, max(0.12, 0.12 + Double(distance) / 2600))
        slide = ColumnSlide(
            edge: edge,
            from: from,
            to: to,
            started: CACurrentMediaTime(),
            duration: duration
        )
        lockColumnFrames()
        placeDividers(updatingCursors: false)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard let running = self.slide else {
                timer.invalidate()
                self.slideTimer = nil
                return
            }
            if CACurrentMediaTime() - running.started >= running.duration {
                self.slide = nil
                timer.invalidate()
                self.slideTimer = nil
                self.lockColumnFrames()
                self.placeDividers()
                completion?()
                return
            }
            self.lockColumnFrames()
            self.placeDividers(updatingCursors: false)
        }
        slideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var flushingPaneLayout = false

    /// Applies the new frame to the SwiftUI content in the same turn. Without this
    /// the hosted scroll view (and the web view in Reading) kept the previous width
    /// while the column moved, so the note showed under the sidebar until the next
    /// unrelated layout pass — the text looked covered while a column was open.
    private func flushPaneLayout(paint: Bool = false) {
        guard !flushingPaneLayout else { return }
        flushingPaneLayout = true
        panes.layoutSubtreeIfNeeded()
        if paint {
            sidebar?.needsDisplay = true
            detail?.needsDisplay = true
            outline?.needsDisplay = true
            detail?.displayIfNeeded()
        }
        flushingPaneLayout = false
    }

    private func logSplit(_ message: String) {
        guard XYZDiagnostics.enabled else { return }
        let side = Int(sidebar?.frame.width ?? -1)
        let detailWidth = Int(detail?.frame.width ?? -1)
        let outlineWidth = Int(outline?.frame.width ?? -1)
        let subviews = detail?.subviews.map { Int($0.frame.width) } ?? []
        let panesBounds = Int(panes.bounds.width)
        XYZDiagnostics.note("\(message) panes=\(panesBounds) side=\(side) detail=\(detailWidth) outline=\(outlineWidth) detailSubviews=\(subviews)")
    }

    /// Adds or removes only the column that changed. `addSubview(_:positioned:)` keeps
    /// the other panes attached to the window, so their hosted text view and web view
    /// are not torn down and do not repaint.
    private func syncPanes() {
        guard let detail else { return }
        if detail.superview !== panes {
            panes.addSubview(detail)
        }
        if sidebarShown, let sidebar {
            if sidebar.superview !== panes {
                panes.addSubview(sidebar, positioned: .below, relativeTo: detail)
            }
        } else if let sidebar, sidebar.superview === panes {
            sidebar.removeFromSuperview()
        }
        if outlineShown, let outline {
            if outline.superview !== panes {
                panes.addSubview(outline, positioned: .above, relativeTo: detail)
            }
        } else if let outline, outline.superview === panes {
            outline.removeFromSuperview()
        }
        placeDividers()
    }

    /// Default about 260. Never the equal split, and never more than 40% of the window.
    private func clampedSidebarWidth() -> CGFloat {
        let cap = max(260, floor(bounds.width * 0.4))
        let room = bounds.width - (outlineShown ? savedOutline : 0) - 480
        let desired = min(max(savedPosition, 220), cap)
        return min(desired, max(220, room))
    }

    private func applyPositions() {
        guard bounds.width > 1 else { return }
        lockColumnFrames()
        placeDividers()
    }

    private func applyOutlineWidthIfNeeded() {
        guard slide == nil, outlineShown, bounds.width > 1 else { return }
        guard let outline else {
            lockColumnFrames()
            return
        }
        // A body update that did not change the width does not need a layout pass.
        guard abs(outline.frame.width - savedOutline) > 0.5 else { return }
        lockColumnFrames()
    }

    /// `position` is the divider's x. The sidebar is to its left. The outline is to the right of the last divider.
    private func rememberDivider(index: Int, position: CGFloat) {
        if index == 0 {
            savedPosition = position
        } else if panes.bounds.width > 1 {
            savedOutline = max(160, panes.bounds.width - position)
        }
        lockColumnFrames()
    }

    /// One double-click. The same content returns the same width.
    private func fitToContent(_ edge: SidebarDivider.Edge) {
        guard bounds.width > 1 else { return }
        switch edge {
        case .left:
            guard sidebarShown else { return }
            let outlineWidth = outlineShown ? (outline?.frame.width ?? savedOutline) : 0
            let width = SidebarFit.sidebar(
                content: measureSidebar(),
                window: bounds.width,
                outline: outlineWidth,
                outlineShown: outlineShown
            )
            savedPosition = width
            sidebarAdjusted = true
            adjusting = true
            lockColumnFrames()
            adjusting = false
            onSidebarWidth?(width)
        case .right:
            guard outlineShown else { return }
            let sidebarWidth = sidebarShown ? (sidebar?.frame.width ?? savedPosition) : 0
            let width = SidebarFit.outline(
                content: measureOutline(),
                window: bounds.width,
                sidebar: sidebarWidth,
                sidebarShown: sidebarShown
            )
            savedOutline = width
            outlineAdjusted = true
            adjusting = true
            lockColumnFrames()
            adjusting = false
            onOutlineWidth?(width)
        }
        placeDividers()
    }

    func testingSidebarFrame() -> NSRect {
        sidebar?.frame ?? .zero
    }

    func testingDetailFrame() -> NSRect {
        detail?.frame ?? .zero
    }

    func testingOutlineFrame() -> NSRect {
        outline?.frame ?? .zero
    }

    func testingDoubleClick(left: Bool) {
        if left {
            leftDivider.fitContent()
        } else {
            rightDivider.fitContent()
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
        dividerDrag = true
        if edge == .left {
            sidebarAdjusted = true
        } else {
            outlineAdjusted = true
        }
        adjusting = true
        rememberDivider(index: index, position: clamped)
        adjusting = false
        if edge == .left {
            onSidebarWidth?(savedPosition)
        }
        sidebar?.layoutSubtreeIfNeeded()
        detail?.layoutSubtreeIfNeeded()
        outline?.layoutSubtreeIfNeeded()
        placeDividers()
        if edge == .right {
            onOutlineWidth?(savedOutline)
        }
    }

    private func placeDividers(updatingCursors: Bool = true) {
        let children = panes.subviews
        if sidebarShown, children.count > 1, children[0] === sidebar {
            let boundary = panes.convert(NSPoint(x: children[0].frame.maxX, y: 0), to: self).x
            place(leftDivider, at: boundary, updatingCursors: updatingCursors)
            leftDivider.isHidden = false
        } else if !leftDivider.isHidden {
            leftDivider.isHidden = true
            if updatingCursors { window?.invalidateCursorRects(for: leftDivider) }
        }
        if outlineShown, children.count > 1 {
            let index = children.count - 2
            let boundary = panes.convert(NSPoint(x: children[index].frame.maxX, y: 0), to: self).x
            place(rightDivider, at: boundary, updatingCursors: updatingCursors)
            rightDivider.isHidden = false
        } else if !rightDivider.isHidden {
            rightDivider.isHidden = true
            if updatingCursors { window?.invalidateCursorRects(for: rightDivider) }
        }
        bringDividersToFront()
    }

    private func place(_ divider: SidebarDivider, at boundary: CGFloat, updatingCursors: Bool = true) {
        let width = SidebarDivider.hitWidth
        let frame = NSRect(x: boundary - width / 2, y: 0, width: width, height: bounds.height)
        let same = abs(divider.frame.origin.x - frame.origin.x) < 0.5
            && abs(divider.frame.size.height - frame.size.height) < 0.5
            && abs(divider.frame.size.width - frame.size.width) < 0.5
        if !same {
            divider.frame = frame
            if updatingCursors { window?.invalidateCursorRects(for: divider) }
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

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if isRightDivider(dividerIndex, in: splitView) {
            return sidebarShown ? 220 + 480 : 480
        }
        return 220
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if isRightDivider(dividerIndex, in: splitView) {
            return max(480, splitView.bounds.width - 160)
        }
        let reserve: CGFloat = outlineShown ? 160 : 0
        let cap = max(260, floor(splitView.bounds.width * 0.4))
        return min(cap, max(220, splitView.bounds.width - 480 - reserve))
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
        guard slide == nil, !adjusting else { return }
        if outlineShown, let outline, outline.superview != nil {
            let width = outline.frame.width
            if abs(width - savedOutline) > 0.5 {
                savedOutline = width
                onOutlineWidth?(width)
            }
        }
        if dividerDrag, sidebarShown, let sidebar, sidebar.superview != nil {
            let cap = max(260, floor(bounds.width * 0.4))
            savedPosition = min(max(220, sidebar.frame.width), cap)
        }
    }
}

/// No system divider. The overlay views draw and drag the edges.
/// A pane that does not report the whole window as its width. The split assigns the frame.
private final class PaneHost<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    private var restoring = false

    override func layout() {
        let kept = frame
        super.layout()
        guard !restoring, superview is NSSplitView, frame.size != kept.size else { return }
        restoring = true
        setFrameSize(kept.size)
        restoring = false
    }
}

private final class PaneSplitView: NSSplitView {
    var lockFrames: (() -> Void)?
    var useDefaultArrange = false
    private var locking = false

    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}
    override func resetCursorRects() {}

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if locking { return }
        locking = true
        defer { locking = false }
        if useDefaultArrange || lockFrames == nil {
            super.resizeSubviews(withOldSize: oldSize)
        } else {
            lockFrames?()
        }
    }
}

/// Width of the names currently shown, measured with the sidebar fonts.
enum SidebarContentMeasure {
    private static let rowFont = NSFont.systemFont(ofSize: 12)
    private static let activeFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let headerTracking: CGFloat = 0.6

    static func explorer(_ session: WorkspaceSession) -> CGFloat {
        MainActor.assumeIsolated {
            var widest = header(session.displayName)
            guard session.rootExpanded else { return widest }
            var pending = [(parent: "", depth: 0)]
            while let next = pending.popLast() {
                for node in session.visibleChildren(of: next.parent) {
                    widest = max(widest, explorerRow(node.name, depth: next.depth))
                    if node.isDirectory, session.isExpanded(node.relativePath) {
                        pending.append((node.relativePath, next.depth + 1))
                    }
                }
            }
            return widest
        }
    }

    static func outline(_ entries: [OutlineEntry]) -> CGFloat {
        var widest = outlineHeader()
        if entries.isEmpty {
            let label = labeled("No Outline", font: rowFont, leading: 16, trailing: 16)
            return max(SidebarFit.outlineMinimum, widest, label)
        }
        for entry in entries {
            widest = max(widest, outlineRow(entry.title, depth: entry.depth))
        }
        return widest
    }

    static func explorerRow(_ name: String, depth: Int) -> CGFloat {
        let text = width(name, font: rowFont)
        let indent = CGFloat(depth) * 16
        let disclosure = OutlineDisclosure.inset
        let iconAndPadding: CGFloat = 2 + 16 + 6 + 6
        return (indent + disclosure + iconAndPadding + text).rounded(.up)
    }

    static func header(_ name: String) -> CGFloat {
        let title = width(name.localizedUppercase, font: headerFont, kern: headerTracking)
        let actions: CGFloat = 4 * 22
        return (12 + 12 + 4 + title + 6 + actions + 4).rounded(.up)
    }

    static func outlineRow(_ title: String, depth: Int) -> CGFloat {
        let text = width(title, font: activeFont)
        let indent = 8 + CGFloat(min(max(depth, 0), 6)) * 12
        return (indent + 14 + 2 + text + 8).rounded(.up)
    }

    static func outlineHeader() -> CGFloat {
        let title = width(String(localized: "Outline").localizedUppercase, font: NSFont.systemFont(ofSize: 11, weight: .medium), kern: headerTracking)
        return (12 + title + 12).rounded(.up)
    }

    private static func labeled(_ text: String, font: NSFont, leading: CGFloat, trailing: CGFloat) -> CGFloat {
        (leading + width(text, font: font) + trailing).rounded(.up)
    }

    private static func width(_ text: String, font: NSFont, kern: CGFloat = 0) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = kern == 0
            ? [.font: font]
            : [.font: font, .kern: kern]
        return (text as NSString).size(withAttributes: attributes).width
    }
}

private enum SidebarDividerColor {
    static func separator(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(xyz: XYZTheme.resolved(dark: dark).divider)
    }

    /// The sash blue, from the theme.
    static var accent: NSColor { .xyzAccent }
}

/// A 5pt grab strip. The resting mark is one pixel. Hover and drag thicken it in the sash blue.
private final class SidebarDivider: NSView {
    enum Edge: String { case left, right }
    static let hitWidth: CGFloat = 5

    let edge: Edge
    var boundaryX: () -> CGFloat = { 0 }
    var moveTo: (CGFloat) -> Void = { _ in }
    var dragEnded: () -> Void = {}
    var fitContent: () -> Void = {}

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
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
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
        setResizeCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        setResizeCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        setResizeCursor()
        inside = true
        XYZDiagnostics.note("divider enter edge=\(edge.rawValue)")
        scheduleHover()
    }

    /// AppKit often skips `cursorUpdate` when a web view or text view is underneath. Setting the cursor here is what the pointer actually uses.
    private func setResizeCursor() {
        NSCursor.resizeLeftRight.set()
        let now = Date()
        if now.timeIntervalSince(lastCursorLog) > 0.4 {
            lastCursorLog = now
            XYZDiagnostics.note("divider cursorUpdate edge=\(edge.rawValue)")
        }
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
        if event.clickCount >= 2 {
            hoverToken += 1
            dragging = false
            setHighlight(on: false, reason: "fit")
            fitContent()
            return
        }
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
        dragEnded()
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
    @State private var sidebar = SidebarVisibility()
    @State private var titlebarInset: CGFloat = 0
    @AppStorage(XYZEditorStyle.wordWrapKey) private var wordWrap = true
    @StateObject private var outline = OutlineModel()
    @AppStorage(HiddenFilesSetting.key) private var storedHiddenFiles = true

    var body: some View {
        VStack(spacing: 0) {
            // A top padding on the full-height host pushes the editor past the window.
            // This row is the title-bar overlap, so the status bar stays inside the frame.
            Color.clear
                .frame(height: titlebarInset)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.xyzDivider)
                        .frame(height: 1)
                        .allowsHitTesting(false)
                }
            WorkspaceSplit(
                showsSidebar: sidebar.shown,
                sidebarVisibility: sidebar,
                showsOutline: showsMarkdownOutline,
                sidebarWidth: session.sidebarWidth,
                sidebarWidthAdjusted: session.sidebarWidthAdjusted,
                outlineWidth: session.outlineWidth,
                outlineWidthAdjusted: session.outlineWidthAdjusted,
                onOutlineWidth: { session.rememberOutlineWidth($0) },
                onSidebarWidth: { session.rememberSidebarWidth($0) },
                sidebarContentWidth: { SidebarContentMeasure.explorer(session) },
                outlineContentWidth: { SidebarContentMeasure.outline(outline.entries) }
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
                    progress: statusEditing ? nil : session.readingProgress,
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
            sidebar: sidebar,
            outlineShown: showsMarkdownOutline,
            outlineEnabled: outlineToggleEnabled,
            readingMode: session.viewMode == .reading,
            modeEnabled: modeToggleEnabled,
            titlebarInset: $titlebarInset,
            onToggleOutline: { session.toggleOutlinePane() },
            onToggleMode: { session.toggleViewMode(source: "titlebar") }
        ))
        .background(
            EditorCommandAnchor(target: commands) {
                commands.attach(session: session, sidebar: sidebar)
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

    /// Reading and editing can be switched only for a file that has both.
    private var modeToggleEnabled: Bool {
        guard let buffer = session.buffer else { return false }
        return EditorModeChoice.canToggle(WorkspaceSession.access(of: buffer))
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
    var sidebar: SidebarVisibility
    var outlineShown: Bool
    var outlineEnabled: Bool
    var readingMode: Bool
    var modeEnabled: Bool
    @Binding var titlebarInset: CGFloat
    var onToggleOutline: () -> Void
    var onToggleMode: () -> Void

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
        view.sidebar = sidebar
        view.outlineShown = outlineShown
        view.outlineEnabled = outlineEnabled
        view.readingMode = readingMode
        view.modeEnabled = modeEnabled
        view.onToggleOutline = onToggleOutline
        view.onToggleMode = onToggleMode
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
    var sidebar: SidebarVisibility? {
        didSet { wireSidebar() }
    }
    private var sidebarShown = true
    var outlineShown = false
    var outlineEnabled = false
    var readingMode = false
    var modeEnabled = false
    var onToggleOutline: () -> Void = {}
    var onToggleMode: () -> Void = {}
    private var sidebarWired = false
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
        wireSidebar()
        apply()
    }

    /// The title-bar buttons read and write the sidebar without going through SwiftUI:
    /// an observer keeps their state, and a click calls `toggle` directly.
    private func wireSidebar() {
        guard !sidebarWired, let sidebar else { return }
        sidebarWired = true
        sidebar.observe { [weak self] shown in
            guard let self, self.sidebarShown != shown else { return }
            self.sidebarShown = shown
            self.titles.updateToggles(
                sidebarShown: shown,
                outlineShown: self.outlineShown,
                outlineEnabled: self.outlineEnabled,
                readingMode: self.readingMode,
                modeEnabled: self.modeEnabled,
                onSidebar: { [weak sidebar] in sidebar?.toggle() },
                onOutline: self.onToggleOutline,
                onMode: self.onToggleMode
            )
        }
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
            readingMode: readingMode,
            modeEnabled: modeEnabled,
            onSidebar: { [weak sidebar] in sidebar?.toggle() },
            onOutline: onToggleOutline,
            onMode: onToggleMode
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
    private var togglesTrailing: NSLayoutConstraint?

    init() {
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .xyzSecondaryText
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
                toggles.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            ]
            let trailing = toggles.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10)
            constraints.append(trailing)
            togglesTrailing = trailing
            NSLayoutConstraint.activate(constraints)
        }
        // Mirror the traffic lights' own metrics: the three centres sit as far from the
        // right edge as the window buttons sit from the left, at the same pitch.
        if let zoom = window.standardWindowButton(.zoomButton) {
            // Work in the frame view's coordinates. `nil` here is window-base coordinates,
            // which carry a different origin and made the mirror land eleven points short.
            let frameView = window.contentView?.superview ?? bar
            let origin = close.convert(NSPoint(x: close.bounds.midX, y: 0), to: frameView).x
            let far = zoom.convert(NSPoint(x: zoom.bounds.midX, y: 0), to: frameView).x
            let pitch = (far - origin) / 2
            let barMax = bar.convert(bar.bounds, to: frameView).maxX
            let mirror = frameView.bounds.width - origin
            let trailingInset = barMax - mirror - TitlebarLayoutToggles.buttonSide / 2
            toggles.applyTrafficLightMetrics(pitch: pitch)
            if let togglesTrailing, abs(togglesTrailing.constant + trailingInset) > 0.5 {
                togglesTrailing.constant = -trailingInset
            }
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
        readingMode: Bool,
        modeEnabled: Bool,
        onSidebar: @escaping () -> Void,
        onOutline: @escaping () -> Void,
        onMode: @escaping () -> Void
    ) {
        toggles.update(
            sidebarShown: sidebarShown,
            outlineShown: outlineShown,
            outlineEnabled: outlineEnabled,
            readingMode: readingMode,
            modeEnabled: modeEnabled,
            onSidebar: onSidebar,
            onOutline: onOutline,
            onMode: onMode
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
    private let sidebar = TitlebarToggleButton(kind: .sidebar)
    private let mode = TitlebarToggleButton(kind: .mode)
    private let outline = TitlebarToggleButton(kind: .outline)
    private var gapConstraints: [NSLayoutConstraint] = []

    /// One 20 pt hit area per glyph. `applyTrafficLightMetrics` places them on the same
    /// centres as the window buttons on the other side, so the two groups mirror each
    /// other whatever the system's own spacing is.
    static let buttonSide: CGFloat = 20

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        sidebar.toolTip = String(localized: "Toggle Left Sidebar (⌘B)")
        mode.toolTip = String(localized: "Toggle Reading and Editing")
        outline.toolTip = String(localized: "Toggle Outline (⌥⌘B)")
        sidebar.setAccessibilityLabel(sidebar.toolTip)
        mode.setAccessibilityLabel(mode.toolTip)
        outline.setAccessibilityLabel(outline.toolTip)
        var previous: NSView?
        for button in [sidebar, outline, mode] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.buttonSide),
                button.heightAnchor.constraint(equalToConstant: Self.buttonSide),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.topAnchor.constraint(equalTo: topAnchor),
            ])
            if let previous {
                let gap = button.leadingAnchor.constraint(equalTo: previous.trailingAnchor)
                gapConstraints.append(gap)
                gap.isActive = true
            } else {
                button.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            }
            previous = button
        }
        mode.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
    }

    /// `pitch` is the distance between two window-button centres. The group's own place in
    /// the bar belongs to `TitlebarTitleInstaller`, which owns that constraint.
    func applyTrafficLightMetrics(pitch: CGFloat) {
        let gap = max(0, pitch - Self.buttonSide)
        // Equal spacing, whatever each button's state is: the row must not move when a
        // pane is opened or the mode changes.
        for constraint in gapConstraints where abs(constraint.constant - gap) > 0.5 {
            constraint.constant = gap
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(
        sidebarShown: Bool,
        outlineShown: Bool,
        outlineEnabled: Bool,
        readingMode: Bool,
        modeEnabled: Bool,
        onSidebar: @escaping () -> Void,
        onOutline: @escaping () -> Void,
        onMode: @escaping () -> Void
    ) {
        sidebar.filled = sidebarShown
        sidebar.onClick = onSidebar
        mode.filled = readingMode
        mode.isToggleEnabled = modeEnabled
        mode.alphaValue = modeEnabled ? 1 : 0.38
        mode.onClick = onMode
        outline.filled = outlineShown
        outline.isToggleEnabled = outlineEnabled
        outline.alphaValue = outlineEnabled ? 1 : 0.38
        outline.onClick = onOutline
        sidebar.needsDisplay = true
        mode.needsDisplay = true
        outline.needsDisplay = true
    }
}

/// Borderless title-bar icon. A filled pane means that pane is open; a filled book means
/// the file is shown in Reading.
final class TitlebarToggleButton: NSView {
    enum Kind { case sidebar, mode, outline }

    let kind: Kind
    var filled = true
    var isToggleEnabled = true
    var onClick: () -> Void = {}

    private var hovered = false
    private var tracking: NSTrackingArea?

    init(kind: Kind) {
        self.kind = kind
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
        // Plain line icons, no discs and no colour: a left pane, a right pane, then the
        // current reading state as a book or a document. An open column is drawn at full
        // ink, a closed one is dimmed, which is enough to read state without colour.
        let enabled = isToggleEnabled
        let color: NSColor = enabled ? .xyzInk : .xyzDisabledTint
        if hovered, enabled {
            NSColor.xyzHover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: NSColor.xyzDisplay.controlCornerRadius, yRadius: NSColor.xyzDisplay.controlCornerRadius).fill()
        }
        drawGlyph(color)
    }

    /// Every icon is drawn in the same 16 by 15 box with the same 1.3 pt stroke, so the
    /// row has one geometry and one weight in both states.
    private func drawGlyph(_ color: NSColor) {
        switch kind {
        case .sidebar, .outline:
            drawPaneGlyph(color)
        case .mode:
            if filled {
                drawBookGlyph(color)
            } else {
                drawDocumentGlyph(color)
            }
        }
    }

    private func glyphBox() -> NSRect {
        NSRect(x: bounds.midX - 8, y: bounds.midY - 7.5, width: 16, height: 15)
    }

    /// An open book: two pages with rounded outer corners that meet at the spine.
    private func drawBookGlyph(_ color: NSColor) {
        let box = glyphBox().insetBy(dx: 0.7, dy: 0.8)
        // Same corner radius as the pane icons; one constant for the whole row.
        let r: CGFloat = 3.0
        let spineX = box.midX
        let dip: CGFloat = 2.2
        color.setStroke()
        let book = NSBezierPath()
        book.move(to: NSPoint(x: spineX, y: box.minY))
        // Left page: bottom edge, rounded bottom-left, left edge, rounded top-left, top edge.
        book.line(to: NSPoint(x: box.minX + r, y: box.minY + 1.1))
        book.curve(
            to: NSPoint(x: box.minX, y: box.minY + 1.1 + r),
            controlPoint1: NSPoint(x: box.minX + r * 0.35, y: box.minY + 1.1),
            controlPoint2: NSPoint(x: box.minX, y: box.minY + 1.1 + r * 0.4)
        )
        book.line(to: NSPoint(x: box.minX, y: box.maxY - r))
        book.curve(
            to: NSPoint(x: box.minX + r, y: box.maxY),
            controlPoint1: NSPoint(x: box.minX, y: box.maxY - r * 0.4),
            controlPoint2: NSPoint(x: box.minX + r * 0.35, y: box.maxY)
        )
        book.line(to: NSPoint(x: spineX, y: box.maxY - dip))
        // Right page, mirrored.
        book.line(to: NSPoint(x: box.maxX - r, y: box.maxY))
        book.curve(
            to: NSPoint(x: box.maxX, y: box.maxY - r),
            controlPoint1: NSPoint(x: box.maxX - r * 0.35, y: box.maxY),
            controlPoint2: NSPoint(x: box.maxX, y: box.maxY - r * 0.4)
        )
        book.line(to: NSPoint(x: box.maxX, y: box.minY + 1.1 + r))
        book.curve(
            to: NSPoint(x: box.maxX - r, y: box.minY + 1.1),
            controlPoint1: NSPoint(x: box.maxX, y: box.minY + 1.1 + r * 0.4),
            controlPoint2: NSPoint(x: box.maxX - r * 0.35, y: box.minY + 1.1)
        )
        book.line(to: NSPoint(x: spineX, y: box.minY))
        book.lineWidth = 1.3
        book.lineJoinStyle = .round
        book.stroke()
        let spine = NSBezierPath()
        spine.move(to: NSPoint(x: spineX, y: box.minY))
        spine.line(to: NSPoint(x: spineX, y: box.maxY - dip))
        spine.lineWidth = 1.1
        spine.stroke()
    }

    /// A document with rounded corners, a folded top-right corner and two text lines.
    private func drawDocumentGlyph(_ color: NSColor) {
        let box = glyphBox().insetBy(dx: 0.7, dy: 0.8)
        let r: CGFloat = 3.0
        let fold: CGFloat = 4.6
        color.setStroke()
        let page = NSBezierPath()
        page.move(to: NSPoint(x: box.minX + r, y: box.minY))
        page.line(to: NSPoint(x: box.maxX - r, y: box.minY))
        page.curve(
            to: NSPoint(x: box.maxX, y: box.minY + r),
            controlPoint1: NSPoint(x: box.maxX - r * 0.35, y: box.minY),
            controlPoint2: NSPoint(x: box.maxX, y: box.minY + r * 0.4)
        )
        page.line(to: NSPoint(x: box.maxX, y: box.maxY - fold))
        page.line(to: NSPoint(x: box.maxX - fold, y: box.maxY))
        page.line(to: NSPoint(x: box.minX + r, y: box.maxY))
        page.curve(
            to: NSPoint(x: box.minX, y: box.maxY - r),
            controlPoint1: NSPoint(x: box.minX + r * 0.35, y: box.maxY),
            controlPoint2: NSPoint(x: box.minX, y: box.maxY - r * 0.4)
        )
        page.line(to: NSPoint(x: box.minX, y: box.minY + r))
        page.curve(
            to: NSPoint(x: box.minX + r, y: box.minY),
            controlPoint1: NSPoint(x: box.minX, y: box.minY + r * 0.4),
            controlPoint2: NSPoint(x: box.minX + r * 0.35, y: box.minY)
        )
        page.close()
        page.lineWidth = 1.3
        page.lineJoinStyle = .round
        page.stroke()
        let crease = NSBezierPath()
        crease.move(to: NSPoint(x: box.maxX - fold, y: box.maxY))
        crease.line(to: NSPoint(x: box.maxX - fold, y: box.maxY - fold))
        crease.line(to: NSPoint(x: box.maxX, y: box.maxY - fold))
        crease.lineWidth = 1.1
        crease.lineJoinStyle = .round
        crease.stroke()
        let rows: [(offset: Int, inset: CGFloat)] = [(0, 2.4), (1, 4.6)]
        for row in rows {
            let y = box.maxY - fold - 3.2 - CGFloat(row.offset) * 3.4
            guard y > box.minY + 1.8 else { break }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: box.minX + 2.2, y: y))
            line.line(to: NSPoint(x: box.maxX - row.inset, y: y))
            line.lineWidth = 1.1
            line.lineCapStyle = .round
            line.stroke()
        }
    }

    /// The pane icons are drawn here rather than taken from SF Symbols: one rounded box
    /// with a divider, the compartment filled when the column is open. The silhouette is
    /// identical in both states, so the row never shifts.
    private func drawPaneGlyph(_ color: NSColor) {
        let rect = NSRect(x: bounds.midX - 8, y: bounds.midY - 7.5, width: 16, height: 15)
        let outer = NSBezierPath(roundedRect: rect.insetBy(dx: 0.65, dy: 0.65), xRadius: 3, yRadius: 3)
        outer.lineWidth = 1.3
        let leading = kind == .sidebar
        let paneWidth = (rect.width * 0.34).rounded()
        let dividerX = leading ? rect.minX + paneWidth : rect.maxX - paneWidth
        if filled {
            // An open column fills its compartment edge to edge, so it reads as "full"
            // next to the hollow state of the closed one.
            let inset: CGFloat = 0.7
            let pane = NSRect(
                x: leading ? rect.minX + inset : dividerX,
                y: rect.minY + inset,
                width: leading ? paneWidth - inset : paneWidth - inset,
                height: rect.height - inset * 2
            )
            NSGraphicsContext.saveGraphicsState()
            outer.addClip()
            color.setFill()
            pane.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        color.setStroke()
        outer.stroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: dividerX, y: rect.minY + 0.65))
        divider.line(to: NSPoint(x: dividerX, y: rect.maxY - 0.65))
        divider.lineWidth = 1.3
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
        window.backgroundColor = .xyzEditor
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
    @AppStorage(RemoteImagesSetting.key) private var loadsRemoteImages = false
    @StateObject private var wordCount = WordCountModel()
    @State private var caret = EditorCaret()
    @State private var surfaceDetail: String?

    var body: some View {
        VStack(spacing: 0) {
            if session.buffer != nil {
                EditorTabBar(session: session)
                if let path = activePath {
                    EditorBreadcrumb(
                        rootName: session.displayName,
                        relativePath: path,
                        siblings: { session.siblingNodes(of: $0) },
                        symbols: markdownSymbols,
                        currentLine: followedLine,
                        chooseSymbol: { line in session.scrollLink.revealLine(line) }
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
        .overlay(alignment: .topTrailing) {
            if let find {
                FindBarHost(model: find)
                    .padding(.top, 8)
                    .padding(.trailing, 12)
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
            find?.noteNewDocument()
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

    /// The line the page follows, the same rule as the outline pane.
    private var followedLine: Int {
        FileOutline.followedLine(
            reading: session.viewMode == .reading,
            viewportLine: session.viewportLine,
            caretLine: caret.line
        )
    }

    /// Headings are the only sections the app treats as one; a JSON key or a code
    /// declaration is not a section the reader scrolls through.
    private var markdownSymbols: [OutlineEntry] {
        format.language == .markdown ? outline.entries : []
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
        // Every language with an outline parser feeds the breadcrumb and the sticky
        // header; only Markdown shows it in the right-hand panel.
        guard let text = session.buffer?.text else {
            outline.clear()
            return
        }
        outline.update(text: text, language: format.language)
        _ = immediate
    }

    private var activePath: String? {
        session.buffer?.relativePath ?? session.tabStrip.activeID
    }

    private var format: FileFormat {
        FileFormats.resolved(
            name: session.buffer?.relativePath ?? activePath ?? "",
            text: session.buffer?.text ?? ""
        )
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
        guard showsWordCount, format.isProse, let text = session.buffer?.text else { return }
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
        EditorModeChoice.showsLineNumbers(mode: session.viewMode, access: fileAccess)
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
            baseDirectory: session.buffer?.url.deletingLastPathComponent(),
            allowsRemoteImages: loadsRemoteImages,
            allowsTaskToggle: !isReadOnly && format.language == .markdown,
            toggleTask: { [weak session] line in
                session?.toggleTask(atLine: line, undoManager: undoManager)
            },
            openTag: { [weak session] tag in
                guard let session else { return }
                EditorCommands.shared.showGlobalSearch(session, query: "#" + tag)
            },
            backlinksHTML: BacklinkHTML.render(session.backlinks)
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
            syntax: format.language,
            forcesMonospace: format.usesCodeFont,
            onSelection: {
                caret = $0
                session.caret = $0
            },
            onTextChange: { newText in
                session.buffer?.userEdited(newText)
                session.previewBridge.send(newText)
                if showsWordCount, format.isProse {
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
    private weak var sidebar: SidebarVisibility?

    func attach(session: WorkspaceSession, sidebar: SidebarVisibility) {
        self.session = session
        self.sidebar = sidebar
        if EditorCommands.shared.target === self {
            EditorCommandState.shared.setOpenFile(session.buffer != nil)
        }
        syncFindSurface()
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
        let opened = session?.beginEditing(source: source) ?? false
        if opened { storedFind.useEditor() }
        return opened
    }
    var showsHiddenFiles: Bool { session?.showsHiddenFiles ?? true }
    var supportsWorkspaceFiles: Bool { session != nil }

    func editorSelect(_ mode: EditorViewMode, source: String) {
        session?.selectViewMode(mode, source: source)
        syncFindSurface()
        if mode == .reading {
            storedFind.showsReplace = false
        }
    }

    private func syncFindSurface() {
        if editorShowsRenderedReading {
            storedFind.useReading(session?.previewHost.webView) { [weak session] in
                session?.buffer?.text ?? ""
            }
        } else {
            storedFind.useEditor()
        }
    }

    func editorToggle(source: String) {
        session?.toggleViewMode(source: source)
        syncFindSurface()
        if session?.viewMode == .reading {
            storedFind.showsReplace = false
        }
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
        sidebar?.toggle()
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

    func editorLineCount() -> Int {
        guard let text = session?.buffer?.text, !text.isEmpty else { return 1 }
        var count = 1
        for byte in text.utf8 where byte == 0x0A {
            count += 1
        }
        return count
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
