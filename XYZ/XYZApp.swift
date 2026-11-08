#if os(macOS)
import AppKit
#endif
import SwiftUI
import XYZCore

@main
struct XYZApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(XYZAppDelegate.self) private var appDelegate
    #endif

    init() {
        AppFonts.register()
    }

    var body: some Scene {
        documents
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
    @AppStorage(XYZEditorStyle.lineNumbersKey) private var lineNumbers = true
    @AppStorage(XYZEditorStyle.relativeLineNumbersKey) private var relativeLineNumbers = false
    @AppStorage(XYZEditorStyle.showWhitespaceKey) private var showsWhitespace = false

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
            Divider()
            Toggle("Line Numbers", isOn: $lineNumbers)
            Toggle("Relative Line Numbers", isOn: $relativeLineNumbers)
            Toggle("Show Whitespace", isOn: $showsWhitespace)
            Divider()
            Button("Fold") {
                NSApp.sendAction(#selector(XYZMacTextView.xyzToggleFold(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Fold All") {
                NSApp.sendAction(#selector(XYZMacTextView.xyzFoldAll(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("[", modifiers: [.command, .option, .shift])
            Button("Unfold All") {
                NSApp.sendAction(#selector(XYZMacTextView.xyzUnfoldAll(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("]", modifiers: [.command, .option, .shift])
        }
    }
}

/// Find commands in the Edit menu. Shortcuts still go through the editor's key monitor
/// when a rendered note needs the web view's own find.
private struct MacFindCommands: Commands {
    @ObservedObject private var editor = EditorCommandState.shared

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") {
                EditorCommands.shared.showFind(nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!editor.hasOpenFile)
            Button("Find and Replace") {
                EditorCommands.shared.showReplace(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!editor.hasOpenFile)
            Button("Use Selection for Find") {
                EditorCommands.shared.useSelectionForFind(nil)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!editor.hasOpenFile)
            Button("Search Notes") {
                EditorCommands.shared.focusFilter(nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            Button("Find Next") {
                EditorCommands.shared.findNext(nil)
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!editor.hasOpenFile)
            Button("Find Previous") {
                EditorCommands.shared.findPrevious(nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!editor.hasOpenFile)
        }
    }
}

private struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About XYZ") {
                AboutWindow.show()
            }
            Button("Manage 'xyz' Command…") {
                XYZCommandInstall.showManage()
            }
        }
        CommandGroup(replacing: .help) {
            Button("XYZ Help") {
                HelpWindow.show()
            }
            .keyboardShortcut("?", modifiers: .command)
        }
        // A Settings scene builds a hidden 500×500 window at launch. This item creates the
        // window only when the user asks for it.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                SettingsWindow.show()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// One short Help window. Replaces the system help item, which otherwise says the app
/// has no help book.
@MainActor
enum HelpWindow {
    private static var panel: NSPanel?

    static func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        AppPanelPlacement.center(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func make() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "XYZ Help")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        EscapeKey.register(panel)
        let host = NSHostingController(rootView: HelpView())
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 440, height: 520))
        return panel
    }
}

private struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Open") {
                    row("Open a folder", "⌘O")
                    row("Quick open", "⌘P")
                    row("Search notes", "⌘K")
                }
                section("Reading and Editing") {
                    row("Switch Reading and Editing", "⌘/")
                    row("Toggle sidebar", "⌘B")
                    row("Toggle outline", "⌥⌘B")
                    row("Zoom in, out, actual size", "⌘+   ⌘−   ⌘0")
                }
                section("Find") {
                    row("Find in note", "⌘F")
                    row("Replace", "⌥⌘F")
                    row("Next and previous match", "⌘G   ⇧⌘G")
                    row("Go to line", "⌃G")
                }
                section("Tabs") {
                    row("Switch tab", "⌘1–⌘9")
                    row("Close tab", "⌘W")
                    row("Reopen closed tab", "⇧⌘T")
                }
                section("Settings") {
                    paragraph("Text size, line spacing, appearance, language, remote images, word count, and hidden files are in Settings.")
                }
                section("Terminal") {
                    paragraph("Manage 'xyz' Command… installs or removes the terminal shortcut. The app is sandboxed, so it writes only to your Homebrew or local bin folder.")
                }
            }
            .padding(22)
        }
        .frame(width: 440)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ shortcut: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
            Spacer(minLength: 8)
            Text(shortcut)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func paragraph(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
