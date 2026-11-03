import SwiftUI
import XYZCore

@main
struct XYZApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(XYZAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        documents

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }

    @SceneBuilder
    private var documents: some Scene {
        documentGroup
        #if os(macOS)
        .defaultSize(width: 980, height: 700)
        .commands {
            AboutCommands()
            WorkspaceCommands()
        }
        #else
        .commands {
            ViewModeCommands()
        }
        #endif
    }

    private var documentGroup: some Scene {
        DocumentGroup(newDocument: { MarkdownFileDocument() }) { configuration in
            DocumentEditorView(
                document: configuration.document,
                isEditable: configuration.isEditable,
                fileURL: configuration.fileURL
            )
        }
    }

}

struct ViewModeCommands: Commands {
    @FocusedValue(\.editorViewActions) private var actions

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            modeToggle("Source", .source)
            modeToggle("Reading", .reading)
            Divider()
            Button("Source Code Mode") {
                actions?.toggle()
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(actions == nil)
        }
    }

    private func modeToggle(_ title: LocalizedStringKey, _ mode: EditorViewMode) -> some View {
        Toggle(title, isOn: Binding(
            get: { actions?.mode == mode },
            set: { isOn in
                if isOn { actions?.select(mode) }
            }
        ))
        .disabled(actions == nil)
    }
}

#if os(macOS)
private struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About XYZ") {
                AboutWindow.show()
            }
        }
    }
}
#endif
