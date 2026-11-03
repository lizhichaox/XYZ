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
    var toggle: () -> Void
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewMode: EditorViewMode = .reading
    #endif
    @State private var bridge: PreviewBridge
    @State private var webHost: PreviewWebHost
    #if os(macOS)
    @StateObject private var commands: DocumentCommandBridge
    #endif
    @AppStorage(WordCountSetting.key) private var showsWordCount = false
    #if os(macOS)
    @AppStorage(XYZEditorStyle.readingLineNumbersKey) private var readingLineNumbers = false
    #endif
    @StateObject private var wordCount = WordCountModel()

    init(document: MarkdownFileDocument, isEditable: Bool, fileURL: URL? = nil) {
        self.document = document
        self.isEditable = isEditable
        self.fileURL = fileURL
        _bridge = State(initialValue: PreviewBridge(text: document.text))
        _webHost = State(initialValue: PreviewWebHost())
        #if os(macOS)
        _commands = StateObject(wrappedValue: DocumentCommandBridge())
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsWordCount {
                WordCountBar(stats: wordCount.stats)
            }
        }
        .background(Color.editorBackground)
        .onAppear {
            if showsWordCount {
                wordCount.update(bridge.latestText, immediate: true)
            }
        }
        .onChange(of: showsWordCount) { _, shown in
            if shown {
                wordCount.update(bridge.latestText, immediate: true)
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 400)
        .background(
            EditorCommandAnchor(target: commands) {
                commands.fileURL = fileURL
                commands.currentText = { [bridge] in bridge.latestText }
            }
        )
        .background(WindowFillAnchor())
        #else
        .focusedSceneValue(
            \.editorViewActions,
            EditorViewActions(
                mode: viewMode,
                select: { select($0, source: "menu") },
                toggle: { toggle(source: "menu") }
            )
        )
        #endif
    }

    private var documentFormat: FileFormat {
        if let name = fileURL?.lastPathComponent {
            return FileFormats.format(for: name)
        }
        return FileFormats.format(for: "Untitled.md")
    }

    private var editor: some View {
        #if os(macOS)
        macEditor
        #else
        iosEditor
        #endif
    }

    #if os(macOS)
    private var macEditor: some View {
        XYZEditor(
            text: document.text,
            isEditable: isEditable && viewMode == .source,
            undoManager: undoManager,
            reloadToken: 0,
            scrollLink: scrollLink,
            markup: TextMarkup.allows(fileExtension: fileURL?.pathExtension),
            spellCheck: TextMarkup.isProse(fileExtension: fileURL?.pathExtension),
            syntax: documentFormat.language,
            forcesMonospace: documentFormat.usesCodeFont,
            onSelection: nil,
            onTextChange: storeEditorText,
            lineNumbersVisible: viewMode == .source || readingLineNumbers,
            find: commands.findModel
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #else
    private var iosEditor: some View {
        XYZEditor(
            text: document.text,
            isEditable: isEditable && viewMode == .source,
            undoManager: undoManager,
            reloadToken: 0,
            scrollLink: scrollLink,
            markup: TextMarkup.allows(fileExtension: fileURL?.pathExtension),
            spellCheck: TextMarkup.isProse(fileExtension: fileURL?.pathExtension),
            syntax: documentFormat.language,
            forcesMonospace: documentFormat.usesCodeFont,
            onSelection: nil,
            onTextChange: storeEditorText
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    private func storeEditorText(_ newText: String) {
        document.storeEditorText(newText)
        bridge.send(newText)
        if showsWordCount {
            wordCount.update(newText)
        }
    }

    private var preview: some View {
        MarkdownPreview(
            bridge: bridge,
            host: webHost,
            scrollLink: scrollLink,
            baseDirectory: fileURL?.deletingLastPathComponent()
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .onAppear {
            webHost.openFile = { url in
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
        #endif
    }

    private var showsMarkdownPreview: Bool {
        viewMode == .reading && TextMarkup.allows(fileExtension: fileURL?.pathExtension)
    }

    @ViewBuilder
    private var singleSurface: some View {
        if showsMarkdownPreview {
            preview
        } else {
            editor
        }
    }

    #if os(macOS)
    private var macBody: some View {
        singleSurface
            .overlay(alignment: .top) {
                if let model = commands.findModel {
                    FindBarHost(model: model)
                }
            }
    }

    private var scrollLink: EditorScrollLink { commands.scrollLink }
    #endif

    #if os(iOS)
    private var iosBody: some View {
        singleSurface
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

    @State private var iosScrollLink = EditorScrollLink()
    private var scrollLink: EditorScrollLink { iosScrollLink }
    #endif

    #if os(iOS)
    private func select(_ mode: EditorViewMode, source: String) {
        if viewMode != mode {
            iosScrollLink.noteToggle(to: mode)
        }
        viewMode = mode
    }

    private func toggle(source: String) {
        select(viewMode.toggled(), source: source)
    }
    #endif
}

#if os(macOS)
@MainActor
final class DocumentCommandBridge: ObservableObject, EditorCommandTarget {
    @Published private(set) var mode: EditorViewMode = .reading
    let scrollLink = EditorScrollLink()
    var fileURL: URL?
    /// The editor's text, for Go to Heading.
    var currentText: () -> String = { "" }

    var editorViewMode: EditorViewMode { mode }
    var editorShowsRenderedReading: Bool {
        mode == .reading && TextMarkup.allows(fileExtension: fileURL?.pathExtension)
    }
    var showsHiddenFiles: Bool { true }
    var supportsWorkspaceFiles: Bool { false }

    func editorSelect(_ mode: EditorViewMode, source: String) {
        let previous = self.mode
        if previous != mode {
            scrollLink.noteToggle(to: mode)
        }
        self.mode = mode
        if mode == .reading {
            findStore.showsReplace = false
        }
        if previous != mode {
            ViewModeLog.changed(from: previous.rawValue, to: mode.rawValue, source: source)
        }
    }

    func editorToggle(source: String) {
        editorSelect(mode.toggled(), source: source)
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

    func paletteHeadings() -> [OutlineHeading] {
        guard TextMarkup.allows(fileExtension: fileURL?.pathExtension) else { return [] }
        return MarkdownOutline.headings(in: currentText())
    }

    func revealHeading(line: Int) {
        scrollLink.revealLine(line)
    }

    var findModel: EditorFindModel? { findStore }
    private let findStore = EditorFindModel()

    func revealPosition(line: Int, column: Int) {
        if mode != .source {
            editorSelect(.source, source: "goto")
            scrollLink.storeQueuedReveal(line, column: column, editorOnly: true)
        } else {
            scrollLink.revealPosition(line, column)
        }
    }
}
#endif
