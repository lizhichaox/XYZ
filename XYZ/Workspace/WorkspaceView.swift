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
        .navigationTitle(titleText)
        .modifier(WorkspaceSubtitle(text: subtitleText))
        .toolbarRole(.editor)
        .frame(minWidth: 880, minHeight: 520)
        .background(WorkspaceWindowChrome(title: titleText))
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

private struct WorkspaceSubtitle: ViewModifier {
    var text: String

    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content.navigationSubtitle(text)
        }
    }
}

/// One title, owned by SwiftUI. AppKit's represented URL was drawing the folder name on top of the file name.
private struct WorkspaceWindowChrome: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> WorkspaceChromeView {
        let view = WorkspaceChromeView()
        view.title = title
        return view
    }

    func updateNSView(_ view: WorkspaceChromeView, context: Context) {
        view.title = title
        view.apply()
    }
}

final class WorkspaceChromeView: NSView {
    var title = ""

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

    func apply() {
        guard let window else { return }
        WorkspaceChrome.apply(to: window, title: title)
    }
}

enum WorkspaceChrome {
    static func apply(to window: NSWindow, title: String) {
        window.representedURL = nil
        window.titleVisibility = .hidden
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
        if window.title != title {
            window.title = title
        }
    }
}

private struct WorkspaceDetail: View {
    @ObservedObject var session: WorkspaceSession
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            if let status = banner {
                bannerView(status)
            }
            ZStack {
                EditorPreviewSplit(
                    mode: layoutMode,
                    fileID: session.buffer?.relativePath ?? "",
                    editor: editor,
                    preview: preview
                )
                .opacity(showsEditor ? 1 : 0)
                .allowsHitTesting(showsEditor)
                if session.buffer == nil {
                    ContentUnavailableView(
                        "No File Open",
                        systemImage: "doc.text",
                        description: Text("Choose a file in the sidebar.")
                    )
                } else if let buffer = session.buffer, !showsEditor {
                    placeholder(for: buffer)
                        .background(Color.editorBackground)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.editorBackground)
        .onChange(of: session.buffer?.editorToken) { _, _ in
            session.previewBridge.send(session.buffer?.text ?? "")
        }
    }

    private var showsEditor: Bool {
        guard let kind = session.buffer?.kind else { return false }
        return kind == .markdown || kind == .plainText
    }

    private var layoutMode: EditorViewMode {
        session.buffer?.kind == .markdown ? session.viewMode : .coding
    }

    private func placeholder(for buffer: WorkspaceFileBuffer) -> some View {
        let tooLarge = buffer.kind == .tooLarge
        return ContentUnavailableView {
            Label(tooLarge ? "File Too Large" : "Can't Edit This File", systemImage: "doc")
        } description: {
            Text(tooLarge ? "This file is too large to edit in XYZ." : "XYZ doesn't edit this file.")
        } actions: {
            Button("Open with Default App") {
                NSWorkspace.shared.open(buffer.url)
            }
        }
    }

    private var banner: String? {
        guard let buffer = session.buffer else { return nil }
        if buffer.isMissing {
            return "This file was removed from the folder."
        }
        if buffer.conflictText != nil {
            return "This file changed on disk."
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
        MarkdownPreview(bridge: session.previewBridge, host: session.previewHost)
    }

    private var editor: some View {
        XYZEditor(
            text: session.buffer?.text ?? "",
            isEditable: showsEditor,
            undoManager: undoManager,
            reloadToken: session.buffer?.editorToken ?? 0,
            onTextChange: { newText in
                session.buffer?.userEdited(newText)
                session.previewBridge.send(newText)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Forwards View-menu and palette actions to the open folder.
@MainActor
final class WorkspaceCommandBridge: EditorCommandTarget {
    private weak var session: WorkspaceSession?
    private var columnVisibility: Binding<NavigationSplitViewVisibility> = .constant(.all)

    func attach(session: WorkspaceSession, columnVisibility: Binding<NavigationSplitViewVisibility>) {
        self.session = session
        self.columnVisibility = columnVisibility
    }

    var editorViewMode: EditorViewMode { session?.viewMode ?? .preview }
    var showsHiddenFiles: Bool { session?.showsHiddenFiles ?? true }
    var supportsWorkspaceFiles: Bool { session != nil }

    func editorSelect(_ mode: EditorViewMode, source: String) {
        session?.selectViewMode(mode, source: source)
    }

    func editorToggleReading(source: String) {
        session?.toggleReadingView(source: source)
    }

    func editorToggleSource(source: String) {
        session?.toggleSourceMode(source: source)
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
}

extension View {
    func workspaceFolderDrop() -> some View {
        onDrop(of: [.fileURL], isTargeted: nil) { providers in
            WorkspaceFolderDrop.handle(providers)
        }
    }
}
#endif
