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
                isEditable: configuration.isEditable
            )
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 700)
        #endif
        .commands {
            PreviewCommands()
            #if os(macOS)
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
