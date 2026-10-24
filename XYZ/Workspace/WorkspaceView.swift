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
    @StateObject private var commands = WorkspaceCommandBridge()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar(session: session)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
        } detail: {
            WorkspaceDetail(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.editorBackground.ignoresSafeArea())
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarRole(.editor)
        .frame(minWidth: 880, minHeight: 520)
        .background(WorkspaceWindowChrome(
            title: titleText,
            subtitle: subtitleText,
            representedFile: session.buffer?.url
        ))
        .background(
            EditorCommandAnchor(target: commands) {
                commands.attach(session: session, columnVisibility: $columnVisibility)
            }
        )
        .workspaceFolderDrop()
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
        openFileName ?? session.displayName
    }

    private var subtitleText: String {
        openFileName == nil ? "" : session.displayName
    }

    private var openFileName: String? {
        if let path = session.selectedPath, let node = session.node(at: path), !node.isDirectory {
            return node.name
        }
        if let path = session.buffer?.relativePath {
            return (path as NSString).lastPathComponent
        }
        return nil
    }
}

/// The window title is the open file. The subtitle is the folder. The proxy icon is that file, never the folder.
private struct WorkspaceWindowChrome: NSViewRepresentable {
    var title: String
    var subtitle: String
    var representedFile: URL?

    func makeNSView(context: Context) -> WorkspaceChromeView {
        let view = WorkspaceChromeView()
        view.title = title
        view.subtitle = subtitle
        view.representedFile = representedFile
        return view
    }

    func updateNSView(_ view: WorkspaceChromeView, context: Context) {
        view.title = title
        view.subtitle = subtitle
        view.representedFile = representedFile
        view.apply()
    }
}

final class WorkspaceChromeView: NSView {
    var title = ""
    var subtitle = ""
    var representedFile: URL?

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
        // NavigationSplitView writes the title during layout. Put the file name back
        // when it does, without touching the title bar when the values already match.
        syncTitle()
    }

    func apply() {
        guard let window else { return }
        WorkspaceChrome.apply(to: window, title: title, subtitle: subtitle, representedFile: representedFile)
    }

    private func syncTitle() {
        guard let window else { return }
        if window.titleVisibility != .visible {
            window.titleVisibility = .visible
        }
        if window.title != title {
            window.title = title
        }
        if window.subtitle != subtitle {
            window.subtitle = subtitle
        }
        if window.representedURL != representedFile {
            window.representedURL = representedFile
        }
    }
}

enum WorkspaceChrome {
    static func apply(to window: NSWindow, title: String, subtitle: String, representedFile: URL?) {
        window.titleVisibility = .visible
        if #available(macOS 26, *) {
            window.titlebarAppearsTransparent = false
            window.titlebarSeparatorStyle = .automatic
            window.toolbarStyle = .automatic
        } else {
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .unified
        }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.backgroundColor = .textBackgroundColor
        if window.title != title {
            window.title = title
        }
        if window.subtitle != subtitle {
            window.subtitle = subtitle
        }
        if window.representedURL != representedFile {
            window.representedURL = representedFile
        }
    }
}

private struct WorkspaceDetail: View {
    @ObservedObject var session: WorkspaceSession
    @Environment(\.undoManager) private var undoManager
    @AppStorage(WordCountSetting.key) private var showsWordCount = false
    @StateObject private var wordCount = WordCountModel()

    var body: some View {
        VStack(spacing: 0) {
            if let status = banner {
                bannerView(status)
            }
            Group {
                if session.buffer == nil {
                    ContentUnavailableView {
                        Label("No File Open", systemImage: "doc.text")
                    } description: {
                        Text("Choose a file in the sidebar.\n⌘P opens one. ⌘⇧F filters the list.")
                    }
                } else if showsReading {
                    preview
                } else if showsEditor {
                    editor
                } else if let buffer = session.buffer {
                    placeholder(for: buffer)
                        .background(Color.editorBackground)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsWordCount && (showsEditor || showsReading) {
                WordCountBar(stats: wordCount.stats)
            }
        }
        .background(Color.editorBackground)
        .onAppear {
            countWords(immediate: true)
        }
        .onChange(of: session.buffer?.editorToken) { _, _ in
            session.previewBridge.send(session.buffer?.text ?? "")
            countWords(immediate: true)
        }
        .onChange(of: showsWordCount) { _, _ in
            countWords(immediate: true)
        }
    }

    private func countWords(immediate: Bool) {
        guard showsWordCount, let text = session.buffer?.text else { return }
        wordCount.update(text, immediate: immediate)
    }

    private var showsEditor: Bool {
        guard let kind = session.buffer?.kind else { return false }
        return kind == .markdown || kind == .plainText
    }

    private var showsReading: Bool {
        session.buffer?.kind == .markdown && session.viewMode == .reading
    }

    private func placeholder(for buffer: WorkspaceFileBuffer) -> some View {
        let tooLarge = buffer.kind == .tooLarge
        return ContentUnavailableView {
            Label(tooLarge ? LocalizedStringKey("File Too Large") : LocalizedStringKey("Can't Edit This File"), systemImage: "doc")
        } description: {
            Text(tooLarge ? LocalizedStringKey("This file is too large to edit in XYZ.") : LocalizedStringKey("XYZ doesn't edit this file."))
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
            isEditable: showsEditor,
            undoManager: undoManager,
            reloadToken: session.buffer?.editorToken ?? 0,
            scrollLink: session.scrollLink,
            markup: session.buffer?.kind == .markdown,
            spellCheck: TextMarkup.isProse(fileExtension: session.buffer?.url.pathExtension),
            onTextChange: { newText in
                session.buffer?.userEdited(newText)
                session.previewBridge.send(newText)
                if showsWordCount {
                    wordCount.update(newText)
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Forwards View-menu and palette actions to the open folder.
@MainActor
final class WorkspaceCommandBridge: ObservableObject, EditorCommandTarget {
    private weak var session: WorkspaceSession?
    private var columnVisibility: Binding<NavigationSplitViewVisibility> = .constant(.all)

    func attach(session: WorkspaceSession, columnVisibility: Binding<NavigationSplitViewVisibility>) {
        self.session = session
        self.columnVisibility = columnVisibility
    }

    var editorViewMode: EditorViewMode { session?.viewMode ?? .source }
    var showsHiddenFiles: Bool { session?.showsHiddenFiles ?? true }
    var supportsWorkspaceFiles: Bool { session != nil }

    func editorSelect(_ mode: EditorViewMode, source: String) {
        session?.selectViewMode(mode, source: source)
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
}

extension View {
    func workspaceFolderDrop() -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            WorkspaceFolderDrop.handle(providers)
        }
    }
}
#endif
