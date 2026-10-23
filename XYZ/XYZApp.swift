import SwiftUI
import XYZCore

@main
struct XYZApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(XYZAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownFileDocument() }) { configuration in
            DocumentEditorView(
                document: configuration.document,
                isEditable: configuration.isEditable,
                fileURL: configuration.fileURL
            )
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 700)
        #endif
        .commands {
            #if os(iOS)
            ViewModeCommands()
            #endif
            #if os(macOS)
            AboutCommands()
            WorkspaceCommands()
            #endif
        }

        #if os(macOS)
        Settings {
            EditorSettingsView()
        }
        #endif
    }
}

#if os(macOS)
private struct EditorSettingsView: View {
    @AppStorage(XYZEditorStyle.monospacedKey) private var monospaced = false

    var body: some View {
        Form {
            Toggle("Monospaced editor font", isOn: $monospaced)
            Text("The editor uses SF Pro, with PingFang SC for Chinese. Turn this on when you want a fixed-width face.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(20)
    }
}
#endif

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

    private func modeToggle(_ title: String, _ mode: EditorViewMode) -> some View {
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
