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

enum ViewModeSymbol {
    static func name(_ mode: EditorViewMode) -> String {
        switch mode {
        case .coding:
            return "chevron.left.forwardslash.chevron.right"
        case .preview:
            return "rectangle.split.2x1"
        case .reading:
            return "book"
        }
    }

    static func help(_ mode: EditorViewMode) -> String {
        switch mode {
        case .coding:
            return "Coding. ⌘/ toggles source code mode."
        case .preview:
            return "Preview. ⌘/ toggles source code mode."
        case .reading:
            return "Reading. ⌘E toggles reading view."
        }
    }
}

struct ViewModeToolbar: ToolbarContent {
    var mode: EditorViewMode
    var onSelect: (EditorViewMode) -> Void

    var body: some ToolbarContent {
        #if os(macOS)
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
            ToolbarItem(id: "xyz.viewMode") {
                ViewModeControl(mode: mode, onSelect: onSelect)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                ViewModeControl(mode: mode, onSelect: onSelect)
            }
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            ViewModeControl(mode: mode, onSelect: onSelect)
        }
        #endif
    }
}

struct ViewModeControl: View {
    var mode: EditorViewMode
    var onSelect: (EditorViewMode) -> Void

    var body: some View {
        #if os(macOS)
        MacViewModeControl(mode: mode, onSelect: onSelect)
        #else
        ViewModeMenu(mode: mode, onSelect: onSelect)
        #endif
    }
}

#if os(macOS)
private struct MacViewModeControl: View {
    var mode: EditorViewMode
    var onSelect: (EditorViewMode) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
            GlassModeControl(mode: mode, onSelect: onSelect, reduceMotion: reduceMotion)
        } else {
            ClassicModeControl(mode: mode, onSelect: onSelect)
        }
    }
}

@available(macOS 26, *)
private struct GlassModeControl: View {
    var mode: EditorViewMode
    var onSelect: (EditorViewMode) -> Void
    var reduceMotion: Bool

    var body: some View {
        // One glass shape. A container around that single effect measures it
        // again in the same frame and logs glassEffect() updating twice.
        HStack(spacing: 0) {
            ForEach(EditorViewMode.allCases) { item in
                segment(item)
            }
        }
        .padding(2)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View mode")
    }

    private func segment(_ item: EditorViewMode) -> some View {
        let selected = mode == item
        return Button {
            onSelect(item)
        } label: {
            Image(systemName: ViewModeSymbol.name(item))
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .symbolEffect(.bounce, value: reduceMotion ? false : selected)
                .frame(width: 34, height: 26)
                .background {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.18))
                        .opacity(selected ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .help(ViewModeSymbol.help(item))
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ClassicModeControl: NSViewRepresentable {
    var mode: EditorViewMode
    var onSelect: (EditorViewMode) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = EditorViewMode.allCases.count
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.setAccessibilityLabel("View mode")
        for (index, item) in EditorViewMode.allCases.enumerated() {
            let image = NSImage(systemSymbolName: ViewModeSymbol.name(item), accessibilityDescription: item.title)
            control.setImage(image, forSegment: index)
            control.setToolTip(ViewModeSymbol.help(item), forSegment: index)
            control.setWidth(36, forSegment: index)
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.pick(_:))
        control.selectedSegment = index(of: mode)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        let selected = index(of: mode)
        if control.selectedSegment != selected {
            control.selectedSegment = selected
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    private func index(of mode: EditorViewMode) -> Int {
        EditorViewMode.allCases.firstIndex(of: mode) ?? 1
    }

    final class Coordinator: NSObject {
        var onSelect: (EditorViewMode) -> Void

        init(onSelect: @escaping (EditorViewMode) -> Void) {
            self.onSelect = onSelect
        }

        @objc func pick(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard EditorViewMode.allCases.indices.contains(index) else { return }
            onSelect(EditorViewMode.allCases[index])
        }
    }
}
#else
private struct ViewModeMenu: View {
    var mode: EditorViewMode
    var onSelect: (EditorViewMode) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            Picker("View", selection: selection) {
                ForEach(EditorViewMode.allCases) { item in
                    Label(item.title, systemImage: ViewModeSymbol.name(item)).tag(item)
                }
            }
        } label: {
            label
        }
        .accessibilityLabel(mode.title)
    }

    private var selection: Binding<EditorViewMode> {
        Binding(get: { mode }, set: { onSelect($0) })
    }

    @ViewBuilder
    private var label: some View {
        let symbol = Image(systemName: ViewModeSymbol.name(mode))
            .symbolRenderingMode(.monochrome)
            .contentTransition(.symbolEffect(.replace))
        if reduceMotion {
            symbol
        } else {
            symbol.symbolEffect(.bounce, value: mode)
        }
    }
}
#endif

/// Editor and Markdown preview for one open document.
struct DocumentEditorView: View {
    let document: MarkdownFileDocument
    let isEditable: Bool

    @Environment(\.undoManager) private var undoManager
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif
    @State private var viewMode: EditorViewMode
    @State private var editingMode: EditorViewMode
    @State private var bridge: PreviewBridge
    @State private var webHost: PreviewWebHost

    init(document: MarkdownFileDocument, isEditable: Bool) {
        self.document = document
        self.isEditable = isEditable
        _bridge = State(initialValue: PreviewBridge(text: document.text))
        _webHost = State(initialValue: PreviewWebHost())
        #if os(iOS)
        let start: EditorViewMode = UIDevice.current.userInterfaceIdiom == .phone ? .coding : .preview
        #else
        let start = EditorViewMode.preview
        #endif
        _viewMode = State(initialValue: start)
        _editingMode = State(initialValue: start == .reading ? .preview : start)
    }

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
        #endif
        .toolbar { ViewModeToolbar(mode: viewMode) { select($0) } }
        .focusedSceneValue(
            \.editorViewActions,
            EditorViewActions(
                mode: viewMode,
                select: { select($0) },
                toggleReading: { toggleReading() },
                toggleSource: { toggleSource() }
            )
        )
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

    private func select(_ mode: EditorViewMode) {
        if mode != .reading {
            editingMode = mode
        }
        viewMode = mode
    }

    private func toggleReading() {
        let next = EditorViewMode.toggleReading(current: viewMode, editing: editingMode)
        editingMode = next.editing
        viewMode = next.mode
    }

    private func toggleSource() {
        let next = EditorViewMode.toggleSource(current: viewMode)
        editingMode = next
        viewMode = next
    }
}
