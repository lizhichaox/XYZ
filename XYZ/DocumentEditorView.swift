import SwiftUI
import XYZCore

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct EditorViewActions {
    var mode: EditorViewMode
    var select: (EditorViewMode) -> Void
    var toggleReading: () -> Void
    var toggleSource: () -> Void
}

private struct EditorViewActionsKey: FocusedValueKey {
    typealias Value = EditorViewActions
}

extension FocusedValues {
    var editorViewActions: EditorViewActions? {
        get { self[EditorViewActionsKey.self] }
        set { self[EditorViewActionsKey.self] = newValue }
    }
}

/// Editor and Markdown preview for one open document.
struct DocumentEditorView: View {
    let document: MarkdownFileDocument
    let isEditable: Bool
    var fileURL: URL? = nil

    @Environment(\.undoManager) private var undoManager
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif
    #if os(iOS)
    @State private var viewMode: EditorViewMode
    @State private var editingMode: EditorViewMode
    #endif
    @State private var bridge: PreviewBridge
    @State private var webHost: PreviewWebHost
    #if os(macOS)
    @StateObject private var commands: DocumentCommandBridge
    #endif

    init(document: MarkdownFileDocument, isEditable: Bool, fileURL: URL? = nil) {
        self.document = document
        self.isEditable = isEditable
        self.fileURL = fileURL
        _bridge = State(initialValue: PreviewBridge(text: document.text))
        _webHost = State(initialValue: PreviewWebHost())
        #if os(macOS)
        _commands = StateObject(wrappedValue: DocumentCommandBridge())
        #endif
        #if os(iOS)
        let start: EditorViewMode = UIDevice.current.userInterfaceIdiom == .phone ? .coding : .preview
        _viewMode = State(initialValue: start)
        _editingMode = State(initialValue: start == .reading ? .preview : start)
        #endif
    }

    #if os(macOS)
    private var viewMode: EditorViewMode { commands.mode }
    #endif

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.editorBackground)
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 400)
        .background(
            EditorCommandAnchor(target: commands) {
                commands.fileURL = fileURL
            }
        )
        #else
        .focusedSceneValue(
            \.editorViewActions,
            EditorViewActions(
                mode: viewMode,
                select: { select($0, source: "menu") },
                toggleReading: { toggleReading(source: "menu") },
                toggleSource: { toggleSource(source: "menu") }
            )
        )
        #endif
    }

    private var editor: some View {
        XYZEditor(
            text: document.text,
            isEditable: isEditable,
            undoManager: undoManager,
            onTextChange: { newText in
                document.storeEditorText(newText)
                bridge.send(newText)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preview: some View {
        MarkdownPreview(bridge: bridge, host: webHost)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if os(macOS)
    private var macBody: some View {
        EditorPreviewSplit(mode: viewMode, editor: editor, preview: preview)
    }
    #endif

    #if os(iOS)
    private var isCompactPhone: Bool {
        horizontalSizeClass == .compact
    }

    private var iosBody: some View {
        Group {
            if isCompactPhone {
                phoneBody
            } else {
                padBody
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: viewMode)
        .onChange(of: viewMode) { _, mode in
            guard mode == .reading else { return }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }

    @ViewBuilder
    private var phoneBody: some View {
        switch viewMode {
        case .coding:
            editor
        case .reading:
            preview
        case .preview:
            VStack(spacing: 0) {
                editor
                Divider()
                preview
            }
        }
    }

    @ViewBuilder
    private var padBody: some View {
        switch viewMode {
        case .coding:
            editor
        case .reading:
            preview
        case .preview:
            HStack(spacing: 0) {
                editor
                Divider()
                preview
            }
        }
    }
    #endif

    #if os(iOS)
    private func select(_ mode: EditorViewMode, source: String) {
        if mode != .reading {
            editingMode = mode
        }
        viewMode = mode
    }

    private func toggleReading(source: String) {
        let next = EditorViewMode.toggleReading(current: viewMode, editing: editingMode)
        editingMode = next.editing
        viewMode = next.mode
    }

    private func toggleSource(source: String) {
        let next = EditorViewMode.toggleSource(current: viewMode)
        editingMode = next
        viewMode = next
    }
    #endif
}

#if os(macOS)
@MainActor
final class DocumentCommandBridge: ObservableObject, EditorCommandTarget {
    @Published private(set) var mode: EditorViewMode = .preview
    private var editingMode: EditorViewMode = .preview
    var fileURL: URL?

    var editorViewMode: EditorViewMode { mode }
    var showsHiddenFiles: Bool { true }
    var supportsWorkspaceFiles: Bool { false }

    func editorSelect(_ mode: EditorViewMode, source: String) {
        let previous = self.mode
        if mode != .reading {
            editingMode = mode
        }
        self.mode = mode
        if previous != mode {
            ViewModeLog.changed(from: previous.rawValue, to: mode.rawValue, source: source)
        }
    }

    func editorToggleReading(source: String) {
        let previous = mode
        let next = EditorViewMode.toggleReading(current: mode, editing: editingMode)
        editingMode = next.editing
        mode = next.mode
        if previous != mode {
            ViewModeLog.changed(from: previous.rawValue, to: mode.rawValue, source: source)
        }
    }

    func editorToggleSource(source: String) {
        let previous = mode
        let next = EditorViewMode.toggleSource(current: mode)
        editingMode = next
        mode = next
        if previous != mode {
            ViewModeLog.changed(from: previous.rawValue, to: mode.rawValue, source: source)
        }
    }

    func paletteFiles() -> [PaletteFile] {
        guard let fileURL else { return [] }
        return [PaletteFile(name: fileURL.lastPathComponent, relativePath: fileURL.path, recency: 1)]
    }

    func paletteOpen(fileID: String, newWindow: Bool) {
        guard newWindow, let fileURL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, _ in }
    }

    func newFile() {
        NSDocumentController.shared.newDocument(nil)
    }

    func reveal() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func copyPath() {
        guard let fileURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fileURL.path, forType: .string)
    }

    func reloadFile() {
        NSApp.sendAction(#selector(NSDocument.revertToSaved(_:)), to: nil, from: nil)
    }
}
#endif
