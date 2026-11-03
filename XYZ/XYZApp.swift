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
            MacViewCommands()
            MacFindCommands()
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
            modeToggle("Editing", .source)
            modeToggle("Reading", .reading)
            Divider()
            Button("Toggle Reading and Editing") {
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
/// View-menu items. `after: .sidebar` disappears when the window has no sidebar toolbar item.
private struct MacViewCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Reading") {
                EditorCommands.shared.selectReading(nil)
            }
            Button("Editing") {
                EditorCommands.shared.selectSource(nil)
            }
            Button("Toggle Reading and Editing") {
                EditorCommands.shared.toggleSource(nil)
            }
            .keyboardShortcut("/", modifiers: .command)
            Divider()
            Button("Toggle Sidebar") {
                EditorCommands.shared.toggleSidebarVisibility(nil)
            }
            .keyboardShortcut("b", modifiers: .command)
        }
    }
}

/// Find commands in the Edit menu. Shortcuts still go through the editor's key monitor
/// when a rendered note needs the web view's own find.
private struct MacFindCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") {
                EditorCommands.shared.showFind(nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("Find and Replace") {
                EditorCommands.shared.showReplace(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Find Next") {
                EditorCommands.shared.findNext(nil)
            }
            .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") {
                EditorCommands.shared.findPrevious(nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }
}

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
