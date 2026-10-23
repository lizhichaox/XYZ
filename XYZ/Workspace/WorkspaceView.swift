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

    var body: some View {
        NavigationSplitView {
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
        .toolbar { ViewModeToolbar(mode: session.viewMode) { session.selectViewMode($0) } }
        .frame(minWidth: 880, minHeight: 520)
        .background(WorkspaceWindowChrome(title: titleText))
        .workspaceFolderDrop()
        .focusedSceneValue(
            \.workspaceActions,
            WorkspaceActions(
                showsHidden: session.showsHiddenFiles,
                toggleHidden: { session.showsHiddenFiles.toggle() },
                focusSearch: { session.focusSearch() }
            )
        )
        .modifier(WorkspaceEditorActions(session: session))
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

    var body: some View {
        if let buffer = session.buffer {
            WorkspaceFilePane(buffer: buffer, mode: session.viewMode)
                .id(buffer.relativePath)
        } else {
            ContentUnavailableView(
                "No File Open",
                systemImage: "doc.text",
                description: Text("Choose a file in the sidebar.")
            )
        }
    }
}

private struct WorkspaceFilePane: View {
    @ObservedObject var buffer: WorkspaceFileBuffer
    var mode: EditorViewMode
    @Environment(\.undoManager) private var undoManager
    @State private var bridge: PreviewBridge
    @State private var webHost: PreviewWebHost

    init(buffer: WorkspaceFileBuffer, mode: EditorViewMode) {
        self.buffer = buffer
        self.mode = mode
        _bridge = State(initialValue: PreviewBridge(text: buffer.text))
        _webHost = State(initialValue: PreviewWebHost())
    }

    var body: some View {
        VStack(spacing: 0) {
            if let status = banner {
                bannerView(status)
            }
            switch buffer.kind {
            case .markdown:
                markdownBody
            case .plainText:
                editor
            case .binary:
                placeholder(
                    title: "Can't Edit This File",
                    systemImage: "doc",
                    message: "XYZ doesn't edit this file."
                )
            case .tooLarge:
                placeholder(
                    title: "File Too Large",
                    systemImage: "doc",
                    message: "This file is too large to edit in XYZ."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.editorBackground)
        .onChange(of: buffer.reloadToken) { _, _ in
            bridge.send(buffer.text)
        }
    }

    private var banner: String? {
        if buffer.isMissing {
            return "This file was removed from the folder."
        }
        if buffer.conflictText != nil {
            return "This file changed on disk."
        }
        return buffer.status
    }

    private func bannerView(_ message: String) -> some View {
        HStack(spacing: 12) {
            Text(message)
            Spacer(minLength: 8)
            if buffer.conflictText != nil {
                Button("Reload") { buffer.reloadFromDisk() }
                Button("Overwrite") { buffer.overwrite() }
            } else if buffer.isMissing && buffer.kind != .binary && buffer.kind != .tooLarge {
                Button("Save Anyway") { buffer.overwrite() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.18))
    }

    private var markdownBody: some View {
        EditorPreviewSplit(mode: mode, editor: editor, preview: preview)
    }

    private var preview: some View {
        MarkdownPreview(bridge: bridge, host: webHost)
    }

    private var editor: some View {
        XYZEditor(
            text: buffer.text,
            isEditable: true,
            undoManager: undoManager,
            reloadToken: buffer.reloadToken,
            onTextChange: { newText in
                buffer.userEdited(newText)
                bridge.send(newText)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("Open with Default App") {
                NSWorkspace.shared.open(buffer.url)
            }
        }
    }
}

/// View menu actions while a Markdown file is the one on screen.
private struct WorkspaceEditorActions: ViewModifier {
    @ObservedObject var session: WorkspaceSession

    func body(content: Content) -> some View {
        if session.buffer?.kind == .markdown {
            content.focusedSceneValue(
                \.editorViewActions,
                EditorViewActions(
                    mode: session.viewMode,
                    select: { session.selectViewMode($0) },
                    toggleReading: { session.toggleReadingView() },
                    toggleSource: { session.toggleSourceMode() }
                )
            )
        } else {
            content
        }
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
