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

/// Explorer, editor, and the Markdown outline. Each divider is 6 points to grab and draws as a 1 point line.
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

final class XYZSplitView: NSSplitView {
    fileprivate var sidebar: NSView?
    fileprivate var detail: NSView?
    fileprivate var outline: NSView?
    var onOutlineWidth: ((CGFloat) -> Void)?
    private var savedPosition: CGFloat = 260
    private var savedOutline: CGFloat = 220
    private var sidebarShown = true
    private var outlineShown = false
    private var loggedDivider = NSRect.null

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = true
        dividerStyle = .thin
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Wide enough to grab. The drawn line stays 1 point.
    override var dividerThickness: CGFloat { subviews.count > 1 ? 6 : 0 }

    private var adjusting = false

    override func layout() {
        super.layout()
        guard !adjusting, bounds.width > 1 else { return }
        adjusting = true
        if sidebarShown, let sidebar, sidebar.superview != nil, sidebar.frame.width < 200 {
            let room = bounds.width - (outlineShown ? savedOutline + dividerThickness : 0) - 480
            setPosition(min(max(savedPosition, 220), max(220, room)), ofDividerAt: 0)
        }
        applyOutlineWidthIfNeeded()
        adjusting = false
    }

    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard subviews.count > 1, dividerThickness > 0 else { return }
        for index in 0..<(subviews.count - 1) {
            let left = subviews[index].frame
            let rect = NSRect(x: left.maxX, y: 0, width: dividerThickness, height: bounds.height)
            addCursorRect(rect, cursor: .resizeLeftRight)
            if index == 0, abs(rect.origin.x - loggedDivider.origin.x) > 0.5 {
                loggedDivider = rect
                XYZDiagnostics.note(String(format: "divider frame=(%.1f,%.1f %.1fx%.1f) cursor=resizeLeftRight", rect.origin.x, rect.origin.y, rect.width, rect.height))
            }
        }
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
        if sidebarShown, let sidebar, sidebar.superview != nil {
            savedPosition = sidebar.frame.width
        }
        sidebarShown = shown
        rebuild()
        applyPositions()
        window?.invalidateCursorRects(for: self)
    }

    func setOutline(shown: Bool, width: CGFloat) {
        savedOutline = width
        guard shown != outlineShown else {
            applyOutlineWidthIfNeeded()
            return
        }
        outlineShown = shown
        rebuild()
        applyPositions()
        window?.invalidateCursorRects(for: self)
    }

    private func rebuild() {
        sidebar?.removeFromSuperview()
        detail?.removeFromSuperview()
        outline?.removeFromSuperview()
        if sidebarShown, let sidebar {
            addSubview(sidebar)
        }
        if let detail {
            addSubview(detail)
        }
        if outlineShown, let outline {
            addSubview(outline)
        }
    }

    private func applyPositions() {
        if sidebarShown, subviews.count > 1, subviews[0] === sidebar {
            let room = bounds.width - (outlineShown ? savedOutline + dividerThickness : 0) - 480
            let position = min(max(savedPosition, 220), max(220, room))
            setPosition(position, ofDividerAt: 0)
        }
        applyOutlineWidthIfNeeded()
    }

    private func applyOutlineWidthIfNeeded() {
        guard outlineShown, let outline, outline.superview != nil, bounds.width > 1 else { return }
        let index = subviews.count - 2
        guard index >= 0 else { return }
        let target = bounds.width - savedOutline - dividerThickness
        if abs(outline.frame.width - savedOutline) > 2 {
            setPosition(target, ofDividerAt: index)
        }
    }

    fileprivate func isRightDivider(_ dividerIndex: Int) -> Bool {
        outlineShown && dividerIndex == subviews.count - 2
    }
}

extension XYZSplitView: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if isRightDivider(dividerIndex) {
            return sidebarShown ? 220 + 480 : 480
        }
        return 220
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if isRightDivider(dividerIndex) {
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
        if outlineShown, let outline, outline.superview != nil {
            let width = outline.frame.width
            if abs(width - savedOutline) > 0.5 {
                savedOutline = width
                onOutlineWidth?(width)
            }
        }
        if sidebarShown, let sidebar, sidebar.superview != nil {
            savedPosition = sidebar.frame.width
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var session: WorkspaceSession
    @Environment(\.undoManager) private var undoManager
    @StateObject private var commands = WorkspaceCommandBridge()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var titlebarInset: CGFloat = 0
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
            titlebarInset: $titlebarInset
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
    @Binding var titlebarInset: CGFloat

    func makeNSView(context: Context) -> WorkspaceChromeView {
        let view = WorkspaceChromeView()
        view.title = title
        view.representedFile = representedFile
        view.onTitlebarInset = { inset in
            if abs(titlebarInset - inset) > 0.5 {
                titlebarInset = inset
            }
        }
        return view
    }

    func updateNSView(_ view: WorkspaceChromeView, context: Context) {
        view.title = title
        view.representedFile = representedFile
        view.onTitlebarInset = { inset in
            if abs(titlebarInset - inset) > 0.5 {
                titlebarInset = inset
            }
        }
        view.apply()
    }
}

final class WorkspaceChromeView: NSView {
    var title = ""
    var representedFile: URL?
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
        if label.superview !== bar {
            NSLayoutConstraint.deactivate(constraints)
            label.removeFromSuperview()
            bar.addSubview(label, positioned: .below, relativeTo: close)
            constraints = [
                label.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: close.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 78),
                label.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -78),
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
