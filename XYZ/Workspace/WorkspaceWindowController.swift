#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    static var controllers: [WorkspaceWindowController] = []
    private static var isTerminating = false

    let session: WorkspaceSession

    init(session: WorkspaceSession) {
        self.session = session
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = session.displayName
        window.representedURL = session.rootURL
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("XYZWorkspace")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: WorkspaceView(session: session))
        session.activate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            session.shutdown()
            Self.controllers.removeAll { $0 === self }
            if !Self.isTerminating {
                Self.persistOpenWindows()
            }
        }
    }

    static func prompt() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Open a folder as a workspace."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Bookmark before this callback returns. The panel's access ends with it.
            let bookmark = try? WorkspaceBookmarks.make(for: url)
            MainActor.assumeIsolated {
                open(url: url, bookmark: bookmark)
            }
        }
    }

    static func open(bookmark: WorkspaceBookmark) {
        guard let url = try? WorkspaceBookmarks.resolve(bookmark.data) else { return }
        open(url: url, bookmark: bookmark.data)
    }

    static func open(url: URL, bookmark: Data? = nil) {
        guard WorkspaceFolders.isDirectory(url) else { return }
        let data = bookmark ?? (try? WorkspaceBookmarks.make(for: url))
        let resolved: URL
        if let data, let url = try? WorkspaceBookmarks.resolve(data) {
            resolved = url
        } else {
            resolved = url
        }
        if let existing = controllers.first(where: { $0.session.rootURL.standardizedFileURL.path == resolved.standardizedFileURL.path }) {
            existing.showWindow(nil)
            NSApp.activate()
            return
        }
        let session = WorkspaceSession(rootURL: resolved, bookmark: data)
        let controller = WorkspaceWindowController(session: session)
        controllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate()
        if let data {
            WorkspaceLibrary.shared.remember(name: resolved.lastPathComponent, data: data, url: resolved)
        }
        persistOpenWindows()
    }

    static func restore() {
        for bookmark in WorkspaceLibrary.shared.openBookmarks {
            open(bookmark: bookmark)
        }
    }

    static func prepareForQuit() {
        isTerminating = true
        for controller in controllers {
            controller.session.shutdown()
        }
        persistOpenWindows()
    }

    private static func persistOpenWindows() {
        let bookmarks = controllers.compactMap { controller -> WorkspaceBookmark? in
            guard let data = controller.session.bookmark else { return nil }
            return WorkspaceBookmark(id: UUID(), name: controller.session.displayName, data: data)
        }
        WorkspaceLibrary.shared.syncOpen(bookmarks)
    }
}

enum WorkspaceFolders {
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

enum WorkspaceFolderDrop {
    static func handle(_ providers: [NSItemProvider]) -> Bool {
        let matches = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matches.isEmpty else { return false }
        for provider in matches {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let found = item as? URL {
                    url = found
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
                } else {
                    url = nil
                }
                guard let url, WorkspaceFolders.isDirectory(url) else { return }
                let bookmark = try? WorkspaceBookmarks.make(for: url)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        WorkspaceWindowController.open(url: url, bookmark: bookmark)
                    }
                }
            }
        }
        return true
    }
}

/// Folder opens and quit cleanup.
///
/// This is not an NSDocumentController. SwiftUI's DocumentGroup installs
/// PlatformDocumentController in applicationWillFinishLaunching, and a
/// controller created earlier crashes that setup.
final class XYZAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            WorkspaceWindowController.restore()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter(WorkspaceFolders.isDirectory)
        guard !folders.isEmpty else { return }
        MainActor.assumeIsolated {
            for url in folders {
                WorkspaceWindowController.open(url: url)
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard WorkspaceFolders.isDirectory(url) else { return false }
        MainActor.assumeIsolated {
            WorkspaceWindowController.open(url: url)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            WorkspaceWindowController.prepareForQuit()
        }
        return .terminateNow
    }
}

struct WorkspaceCommands: Commands {
    @ObservedObject private var library = WorkspaceLibrary.shared
    @FocusedValue(\.workspaceActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") {
                WorkspaceWindowController.prompt()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Menu("Open Recent Folder") {
                if library.recents.isEmpty {
                    Button("No Recent Folders") {}
                        .disabled(true)
                } else {
                    ForEach(library.recents) { recent in
                        Button(recent.name) {
                            WorkspaceWindowController.open(bookmark: recent)
                        }
                    }
                }
                Divider()
                Button("Clear Menu") {
                    library.clearRecents()
                }
                .disabled(library.recents.isEmpty)
            }

            Button(actions?.showsHidden == false ? "Show Hidden Files" : "Hide Hidden Files") {
                actions?.toggleHidden()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }
    }
}
#endif
