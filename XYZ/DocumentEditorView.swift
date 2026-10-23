import SwiftUI
import XYZCore

#if os(iOS)
import UIKit
#endif

struct ShowsPreviewKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var xyzShowsPreview: Binding<Bool>? {
        get { self[ShowsPreviewKey.self] }
        set { self[ShowsPreviewKey.self] = newValue }
    }
}

/// Editor and Markdown preview for one open document.
struct DocumentEditorView: View {
    let document: MarkdownFileDocument
    let isEditable: Bool

    @Environment(\.undoManager) private var undoManager
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var showsPreview: Bool
    @State private var bridge: PreviewBridge

    init(document: MarkdownFileDocument, isEditable: Bool) {
        self.document = document
        self.isEditable = isEditable
        _bridge = State(initialValue: PreviewBridge(text: document.text))
        #if os(iOS)
        let startWithPreview = UIDevice.current.userInterfaceIdiom != .phone
        #else
        let startWithPreview = true
        #endif
        _showsPreview = State(initialValue: startWithPreview)
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
        .toolbar { toolbarContent }
        .focusedSceneValue(\.xyzShowsPreview, $showsPreview)
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
        MarkdownPreview(bridge: bridge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if os(macOS)
    private var macBody: some View {
        HSplitView {
            editor
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            if showsPreview {
                preview
                    .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    #endif

    #if os(iOS)
    private var isCompactPhone: Bool {
        horizontalSizeClass == .compact
    }

    @ViewBuilder
    private var iosBody: some View {
        if isCompactPhone {
            phoneBody
        } else {
            padBody
        }
    }

    private var phoneBody: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $showsPreview) {
                Text("Edit").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityLabel("Edit or preview")

            ZStack {
                editor
                    .opacity(showsPreview ? 0 : 1)
                    .allowsHitTesting(!showsPreview)
                    .accessibilityHidden(showsPreview)
                preview
                    .opacity(showsPreview ? 1 : 0)
                    .allowsHitTesting(showsPreview)
                    .accessibilityHidden(!showsPreview)
            }
        }
        .onChange(of: showsPreview) { _, visible in
            if visible {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
        }
    }

    private var padBody: some View {
        HStack(spacing: 0) {
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsPreview {
                Divider()
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    #endif

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $showsPreview) {
                Label("Preview", systemImage: showsPreview ? "eye.fill" : "eye")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(showsPreview ? "Hide preview" : "Show preview")
            .accessibilityLabel(showsPreview ? "Hide preview" : "Show preview")
        }
        #else
        if !isCompactPhone {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsPreview.toggle()
                } label: {
                    Label("Preview", systemImage: showsPreview ? "eye.fill" : "eye")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(showsPreview ? "Hide preview" : "Show preview")
            }
        }
        #endif
    }
}
