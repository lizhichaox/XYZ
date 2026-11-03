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

struct WorkspaceView: View {
    @ObservedObject var session: WorkspaceSession
    @Environment(\.undoManager) private var undoManager
    @StateObject private var commands = WorkspaceCommandBridge()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var trafficInset: CGFloat = 80
    @State private var sidebarWidth: CGFloat = 0
    @AppStorage(HiddenFilesSetting.key) private var storedHiddenFiles = true

    var body: some View {
        HSplitView {
            if columnVisibility != .detailOnly {
                WorkspaceSidebar(session: session, undoManager: undoManager)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 420)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: SidebarWidthKey.self, value: proxy.size.width)
                    })
            }
            WorkspaceDetail(
                session: session,
                find: commands.findModel
            )
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .background(Color.editorBackground)
        }
        .onPreferenceChange(SidebarWidthKey.self) { sidebarWidth = $0 }
        .onChange(of: columnVisibility) { _, value in
            if value == .detailOnly {
                sidebarWidth = 0
            }
        }
        .frame(minWidth: 880, minHeight: 520)
        .background(WorkspaceWindowChrome(
            title: titleText,
            representedFile: session.buffer?.url,
            session: session,
            tabLeading: columnVisibility == .detailOnly ? trafficInset : sidebarWidth,
            trafficInset: $trafficInset
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
        .focusedSceneValue(
            \.workspaceActions,
            WorkspaceActions(
                showsHidden: session.showsHiddenFiles,
                toggleHidden: { session.showsHiddenFiles.toggle() },
                focusSearch: { session.focusSearch() }
            )
        )
    }

    private var titleText: String {
        openFilePath.map { ($0 as NSString).lastPathComponent } ?? session.displayName
    }

    private var openFilePath: String? {
        if let path = session.selectedPath, let node = session.node(at: path), !node.isDirectory {
            return node.relativePath
        }
        return session.buffer?.relativePath
    }
}

/// The window title is the open file. The subtitle is the folder. The proxy icon is that file, never the folder.
private struct SidebarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WorkspaceWindowChrome: NSViewRepresentable {
    var title: String
    var representedFile: URL?
    var session: WorkspaceSession
    var tabLeading: CGFloat
    @Binding var trafficInset: CGFloat

    func makeNSView(context: Context) -> WorkspaceChromeView {
        let view = WorkspaceChromeView()
        view.title = title
        view.representedFile = representedFile
        view.session = session
        view.tabLeading = tabLeading
        view.onTrafficInset = { inset in
            if abs(trafficInset - inset) > 0.5 {
                trafficInset = inset
            }
        }
        return view
    }

    func updateNSView(_ view: WorkspaceChromeView, context: Context) {
        view.title = title
        view.representedFile = representedFile
        view.session = session
        view.tabLeading = tabLeading
        view.onTrafficInset = { inset in
            if abs(trafficInset - inset) > 0.5 {
                trafficInset = inset
            }
        }
        view.apply()
    }
}

final class WorkspaceChromeView: NSView {
    var title = ""
    var representedFile: URL?
    weak var session: WorkspaceSession?
    var tabLeading: CGFloat = 0
    var onTrafficInset: (CGFloat) -> Void = { _ in }
    private var tabs: TitlebarTabsController?

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
        // SwiftUI can put the title and the sidebar toolbar back during layout.
        syncTitle()
        reportTrafficInset()
        installTabs()
    }

    func apply() {
        guard let window else { return }
        syncTitle()
        reportTrafficInset()
        installTabs()
    }

    /// The file name stays on the window for the Window menu. The title bar does not draw it.
    private func syncTitle() {
        guard let window else { return }
        WorkspaceChrome.apply(to: window, title: title, subtitle: "", representedFile: representedFile)
    }

    private func reportTrafficInset() {
        guard let window else { return }
        let lights = window.standardWindowButton(.zoomButton)?.frame.maxX ?? 70
        onTrafficInset(lights + 12)
    }

    /// Tabs live in the title bar, not under the title-bar view.
    private func installTabs() {
        guard let window, let session else { return }
        let current = window.titlebarAccessoryViewControllers.compactMap { $0 as? TitlebarTabsController }.first
        let controller = current ?? TitlebarTabsController(session: session)
        if current == nil {
            window.addTitlebarAccessoryViewController(controller)
        }
        controller.update(session: session, leading: tabLeading)
        tabs = controller
    }
}

/// Full-width title-bar row. The system sets the width; the height is the tab strip.
final class TitlebarTabsController: NSTitlebarAccessoryViewController {
    private let host: NSHostingView<EditorTabBar>
    private weak var session: WorkspaceSession?
    private var leading: CGFloat = -1

    init(session: WorkspaceSession) {
        host = NSHostingView(rootView: EditorTabBar(session: session, leading: 0))
        host.safeAreaRegions = []
        super.init(nibName: nil, bundle: nil)
        self.session = session
        identifier = NSUserInterfaceItemIdentifier("xyz.titlebar.tabs")
        layoutAttribute = .bottom
        automaticallyAdjustsSize = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 30))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.frame.size.height = 30
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(session: WorkspaceSession, leading: CGFloat) {
        let sameSession = session === self.session
        guard !sameSession || abs(leading - self.leading) > 0.5 else { return }
        self.session = session
        self.leading = leading
        host.rootView = EditorTabBar(session: session, leading: leading)
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
        // NavigationSplitView used to put a sidebar button in a bar that covered the tabs.
        if window.toolbar != nil {
            window.toolbar = nil
        }
        Self.clearTitlebarFill(of: window)
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

    /// The title-bar material is what paints over SwiftUI content in that strip.
    /// Buttons stay; the fill behind them does not.
    private static func clearTitlebarFill(of window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton) else { return }
        var cursor: NSView? = close
        var ancestors = Set<ObjectIdentifier>()
        while let view = cursor {
            ancestors.insert(ObjectIdentifier(view))
            cursor = view.superview
        }
        guard let root = window.contentView?.superview else { return }
        func walk(_ view: NSView) {
            let coversButtons = ancestors.contains(ObjectIdentifier(view))
            if let effect = view as? NSVisualEffectView, !coversButtons {
                effect.alphaValue = 0
            }
            view.subviews.forEach(walk)
        }
        walk(root)
    }
}

private struct WorkspaceDetail: View {
    @ObservedObject var session: WorkspaceSession
    var find: EditorFindModel?
    @Environment(\.undoManager) private var undoManager
    @AppStorage(WordCountSetting.key) private var showsWordCount = false
    @StateObject private var wordCount = WordCountModel()
    @StateObject private var outline = OutlineModel()
    @State private var caret = EditorCaret()
    @State private var surfaceDetail: String?
    @AppStorage(OutlineSetting.key) private var showsOutline = false
    @AppStorage(XYZEditorStyle.readingLineNumbersKey) private var readingLineNumbers = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let find, find.visible {
                        EditorFindBar(model: find)
                    }
                    if let path = activePath {
                        EditorBreadcrumb(rootName: session.displayName, relativePath: path) { crumb in
                            session.revealCrumb(crumb)
                        }
                    }
                    if let status = banner {
                        bannerView(status)
                    }
                    fileBody
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsOutline && editableText {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                    OutlinePane(entries: outline.entries) { line in
                        session.scrollLink.revealLine(line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.buffer != nil {
                EditorStatusBar(
                    caret: showsText ? caret : nil,
                    encodingValue: showsText ? session.buffer?.encoding : nil,
                    lineEndingValue: showsText ? session.buffer?.lineEnding : nil,
                    mixedEndings: session.buffer?.mixedLineEndings == true,
                    typeName: statusMode,
                    words: format.isProse && !isReadOnly ? wordCount.stats : nil,
                    showsReadingTime: showsWordCount && format.isProse && !isReadOnly,
                    detail: isReadOnly && session.buffer?.previewTruncated == true
                        ? String(localized: "Preview truncated")
                        : (showsText ? nil : surfaceDetail),
                    onEncoding: isEditing ? { session.chooseEncoding($0) } : nil,
                    onLineEnding: isEditing ? { session.chooseLineEnding($0) } : nil
                )
            }
        }
        .background(Color.editorBackground)
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
            surfaceDetail = nil
            countWords(immediate: true)
            refreshOutline(immediate: true)
        }
        .onChange(of: showsWordCount) { _, _ in
            countWords(immediate: true)
        }
        .onChange(of: showsOutline) { _, shown in
            if shown { refreshOutline(immediate: true) }
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
                Text("Choose a file in the sidebar.\n⌘P opens one. ⌘⇧F searches names and text.")
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

    private func refreshOutline(immediate: Bool) {
        guard showsOutline, showsText, let text = session.buffer?.text else { return }
        if immediate {
            outline.update(text: text, language: format.language)
        } else {
            outline.update(text: text, language: format.language)
        }
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
            onSelection: { caret = $0 },
            onTextChange: { newText in
                session.buffer?.userEdited(newText)
                session.previewBridge.send(newText)
                if format.isProse {
                    wordCount.update(newText)
                }
                if showsOutline {
                    outline.update(text: newText, language: format.language)
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
    }

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

    func focusFilter() {
        session?.focusSearch()
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
