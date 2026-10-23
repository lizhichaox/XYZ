import SwiftUI
import XYZCore

@main
struct XYZApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownFileDocument() }) { configuration in
            DocumentEditorView(
                document: configuration.document,
                isEditable: configuration.isEditable
            )
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 700)
        #endif
        .commands {
            PreviewCommands()
        }
    }
}

struct PreviewCommands: Commands {
    @FocusedValue(\.xyzShowsPreview) private var showsPreview

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(showsPreview?.wrappedValue == true ? "Hide Preview" : "Show Preview") {
                showsPreview?.wrappedValue.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(showsPreview == nil)
        }
    }
}
