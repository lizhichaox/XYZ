#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

struct WorkspaceActions {
    var showsHidden: Bool
    var toggleHidden: () -> Void
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
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 420)
        } detail: {
            WorkspaceDetail(session: session)
        }
        .frame(minWidth: 720, minHeight: 420)
        .background(Color.editorBackground)
        .workspaceFolderDrop()
        .focusedSceneValue(
            \.workspaceActions,
            WorkspaceActions(
                showsHidden: session.showsHiddenFiles,
                toggleHidden: { session.showsHiddenFiles.toggle() }
            )
        )
    }

    private var sidebar: some View {
        List(selection: $session.selectedPath) {
            if session.children[""] == nil && session.rootError == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            } else if let rootError = session.rootError {
                Text(rootError)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                WorkspaceOutline(session: session, parent: "")
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Folder contents")
        .onChange(of: session.selectedPath) { _, path in
            guard let path, let node = session.node(at: path), !node.isDirectory else { return }
            session.openFile(node)
        }
    }
}

private struct WorkspaceOutline: View {
    @ObservedObject var session: WorkspaceSession
    var parent: String

    var body: some View {
        ForEach(session.visibleChildren(of: parent)) { node in
            if node.isDirectory {
                DisclosureGroup(isExpanded: expansion(node)) {
                    if session.isExpanded(node.relativePath) {
                        directoryBody(node)
                    }
                } label: {
                    WorkspaceRow(session: session, node: node)
                }
            } else {
                WorkspaceRow(session: session, node: node)
                    .tag(node.relativePath as String?)
            }
        }
    }

    @ViewBuilder
    private func directoryBody(_ node: WorkspaceNode) -> some View {
        if session.children[node.relativePath] == nil && session.loadErrors[node.relativePath] == nil {
            ProgressView()
                .controlSize(.small)
        } else if let message = session.loadErrors[node.relativePath] {
            Text(message)
                .foregroundStyle(.secondary)
        } else {
            WorkspaceOutline(session: session, parent: node.relativePath)
        }
    }

    private func expansion(_ node: WorkspaceNode) -> Binding<Bool> {
        Binding(
            get: { session.isExpanded(node.relativePath) },
            set: { session.setExpanded(node, $0) }
        )
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var session: WorkspaceSession
    var node: WorkspaceNode

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: WorkspaceIcons.image(for: session.url(for: node.relativePath)))
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu {
            if !node.isDirectory {
                Button("Open with Default App") {
                    NSWorkspace.shared.open(session.url(for: node.relativePath))
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.url(for: node.relativePath)])
            }
        }
    }
}

private struct WorkspaceDetail: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        if let buffer = session.buffer {
            WorkspaceFilePane(buffer: buffer)
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
    @Environment(\.undoManager) private var undoManager
    @State private var showsPreview: Bool
    @State private var bridge: PreviewBridge

    init(buffer: WorkspaceFileBuffer) {
        self.buffer = buffer
        _showsPreview = State(initialValue: buffer.kind == .markdown)
        _bridge = State(initialValue: PreviewBridge(text: buffer.text))
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
        .toolbar {
            if buffer.kind == .markdown {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $showsPreview) {
                        Label("Preview", systemImage: showsPreview ? "eye.fill" : "eye")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .help(showsPreview ? "Hide preview" : "Show preview")
                }
            }
        }
        .modifier(PreviewFocusModifier(isEnabled: buffer.kind == .markdown, showsPreview: $showsPreview))
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
        HSplitView {
            editor
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            if showsPreview {
                MarkdownPreview(bridge: bridge)
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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

/// Attaches the preview command only while a Markdown file is in front.
private struct PreviewFocusModifier: ViewModifier {
    var isEnabled: Bool
    @Binding var showsPreview: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.focusedSceneValue(\.xyzShowsPreview, $showsPreview)
        } else {
            content
        }
    }
}

enum WorkspaceIcons {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    static func image(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        cache.setObject(image, forKey: key)
        return image
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
