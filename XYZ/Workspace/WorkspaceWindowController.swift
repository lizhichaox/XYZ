#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XYZCore

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    static var controllers: [WorkspaceWindowController] = []
    private static var isTerminating = false

    private(set) var session: WorkspaceSession

    init(session: WorkspaceSession) {
        self.session = session
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Title is the open file (the folder name until a file is open). The proxy icon
        // stays nil here so a folder URL is not drawn on top of that name.
        window.title = session.displayName
        WorkspaceChrome.apply(to: window, title: session.displayName, subtitle: "", representedFile: nil)
        window.styleMask.insert(.fullSizeContentView)
        window.contentMinSize = NSSize(width: 880, height: 520)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = false
        super.init(window: window)
        adopt(session)
        window.delegate = self
        session.activate()
    }

    /// The workspace window that owns `window`, when there is one.
    static func controller(for window: NSWindow) -> WorkspaceWindowController? {
        controllers.first { $0.window === window }
    }

    /// Replaces this window's folder. Other windows are left as they are.
    func promptSwitchFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Open Folder")
        panel.message = String(localized: "Open a folder as a workspace.")
        panel.showsHiddenFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let bookmark: Data?
            do {
                bookmark = try WorkspaceBookmarks.make(for: url)
            } catch {
                bookmark = nil
                WorkspaceLog.bookmarkFailed(action: "save", path: url.path, error: error)
            }
            MainActor.assumeIsolated {
                self?.switchFolder(url: url, bookmark: bookmark)
            }
        }
    }

    func switchFolder(url: URL, bookmark: Data?) {
        guard WorkspaceFolders.isDirectory(url) else { return }
        let data = bookmark ?? WorkspaceBookmarks.capture(url)
        var resolved = url
        if let data {
            var stale = false
            do {
                resolved = try WorkspaceBookmarks.resolve(data, isStale: &stale)
            } catch {
                resolved = url
            }
        }
        if resolved.standardizedFileURL.path == session.rootURL.standardizedFileURL.path {
            return
        }
        session.shutdown()
        let next = WorkspaceSession(rootURL: resolved, bookmark: data)
        adopt(next)
        next.activate()
        if let data {
            WorkspaceLibrary.shared.remember(name: resolved.lastPathComponent, data: data, url: resolved)
        }
        Self.persistOpenWindows()
        WorkspaceLog.folderPicked(source: "switch-folder", path: resolved.path)
    }

    private func adopt(_ session: WorkspaceSession) {
        self.session = session
        session.claimExistingFile = { [weak self] path in
            guard let self else { return false }
            return Self.focusElsewhere(root: self.session.rootURL, path: path, except: self)
        }
        session.onTabsChanged = { [weak self] in
            guard let self, !Self.isTerminating else { return }
            Self.persistOpenWindows()
        }
        session.onMoveTab = { [weak self] id in
            self?.moveTabToNewWindow(id)
        }
        guard let window else { return }
        let host = NSHostingController(rootView: WorkspaceView(session: session))
        // The title bar stays, but it must not push the tabs and the filter down a second row.
        host.safeAreaRegions = []
        window.contentViewController = host
        WorkspaceChrome.apply(to: window, title: session.displayName, subtitle: "", representedFile: nil)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if let window {
            WindowFill.fillOnce(window)
        }
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

    /// A new window on the key folder, or the folder panel when no folder window is key.
    static func newWindow() {
        if let current = controllers.first(where: { $0.window?.isKeyWindow == true }) {
            _ = open(url: current.session.rootURL, bookmark: current.session.bookmark, fresh: true)
            return
        }
        prompt(fresh: true)
    }

    func moveTabToNewWindow(_ id: String) {
        guard let tab = session.detachForMove(id) else { return }
        guard let destination = Self.open(url: session.rootURL, bookmark: session.bookmark, fresh: true) else { return }
        let name = (id as NSString).lastPathComponent
        destination.session.openFile(
            WorkspaceNode(
                name: name,
                relativePath: id,
                isDirectory: false,
                isHidden: WorkspacePaths.isHidden(name: name, resourceHidden: false)
            ),
            pin: !tab.isPreview,
            mode: tab.mode,
            adoptExisting: false
        )
    }

    static func prompt(fresh: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Open Folder")
        panel.message = String(localized: "Open a folder as a workspace.")
        panel.showsHiddenFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                WorkspaceLog.panelCancelled(kind: "open-folder")
                return
            }
            WorkspaceLog.folderPicked(source: "open-folder", path: url.path)
            // Bookmark before this callback returns. The panel's access ends with it.
            let bookmark: Data?
            do {
                bookmark = try WorkspaceBookmarks.make(for: url)
                if let bookmark {
                    WorkspaceLog.bookmarkSaved(path: url.path, bytes: bookmark.count)
                }
            } catch {
                bookmark = nil
                WorkspaceLog.bookmarkFailed(action: "save", path: url.path, error: error)
            }
            MainActor.assumeIsolated { () -> Void in
                _ = open(url: url, bookmark: bookmark, fresh: fresh)
            }
        }
    }

    @discardableResult
    static func open(bookmark: WorkspaceBookmark, fresh: Bool = false, tabs: WorkspaceWindowState? = nil) -> WorkspaceWindowController? {
        do {
            let url = try WorkspaceBookmarks.resolve(bookmark.data)
            return open(url: url, bookmark: bookmark.data, fresh: fresh, tabs: tabs)
        } catch {
            WorkspaceLog.bookmarkFailed(action: "restore", path: bookmark.name, error: error)
            return nil
        }
    }

    @discardableResult
    static func open(
        url: URL,
        bookmark: Data? = nil,
        fresh: Bool = false,
        tabs: WorkspaceWindowState? = nil
    ) -> WorkspaceWindowController? {
        guard WorkspaceFolders.isDirectory(url) else {
            WorkspaceLog.rejected(path: url.path, reason: "not-a-folder")
            return nil
        }
        let data = bookmark ?? WorkspaceBookmarks.capture(url)
        let resolved: URL
        if let data {
            var stale = false
            do {
                resolved = try WorkspaceBookmarks.resolve(data, isStale: &stale)
                WorkspaceLog.bookmarkRestored(path: resolved.path, stale: stale)
            } catch {
                WorkspaceLog.bookmarkFailed(action: "restore", path: url.path, error: error)
                resolved = url
            }
        } else {
            resolved = url
        }
        if !fresh, let existing = controllers.first(where: { $0.session.rootURL.standardizedFileURL.path == resolved.standardizedFileURL.path }) {
            existing.showWindow(nil)
            NSApp.activate()
            WorkspaceLog.workspaceWindow(path: resolved.path, state: "focused", openWindows: controllers.count)
            return existing
        }
        let session = WorkspaceSession(rootURL: resolved, bookmark: data)
        let controller = WorkspaceWindowController(session: session)
        controllers.append(controller)
        if let tabs {
            session.restoreTabs(tabs)
        }
        controller.showWindow(nil)
        NSApp.activate()
        WorkspaceLog.workspaceWindow(path: resolved.path, state: "opened", openWindows: controllers.count)
        if let data {
            WorkspaceLibrary.shared.remember(name: resolved.lastPathComponent, data: data, url: resolved)
        }
        persistOpenWindows()
        return controller
    }

    /// A file open in another window of the same folder. That window comes forward.
    static func focusElsewhere(root: URL, path: String, except: WorkspaceWindowController) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let tabs = controllers.map { controller -> [String] in
            guard controller.session.rootURL.standardizedFileURL.path == rootPath else { return [] }
            return controller.session.tabStrip.tabs.map(\.id)
        }
        guard let index = controllers.firstIndex(where: { $0 === except }) else { return false }
        guard let found = WorkspaceFileFocus.otherWindow(containing: path, tabs: tabs, current: index) else { return false }
        let controller = controllers[found]
        _ = controller.session.selectTab(id: path)
        controller.showWindow(nil)
        NSApp.activate()
        return true
    }

    /// The last saved folder, when launch has nothing to restore.
    static func reopenLastFolder() {
        if let saved = WorkspaceLibrary.shared.windows.first {
            _ = open(
                bookmark: saved.bookmark,
                tabs: WorkspaceWindowState(tabs: saved.tabs, activePath: saved.activePath)
            )
            return
        }
        if let recent = WorkspaceLibrary.shared.recents.first {
            _ = open(bookmark: recent)
        }
    }

    /// DocumentGroup can leave an untitled window and a hidden filled window beside the folder windows.
    static func closeStrayWindows() {
        for document in NSDocumentController.shared.documents where document.fileURL == nil {
            document.close()
        }
        for window in NSApp.windows {
            if window is NSPanel { continue }
            if controller(for: window) != nil { continue }
            if window.isVisible { continue }
            if EscapeKey.isRegistered(window) { continue }
            window.close()
        }
        closePhantomWindows()
    }

    private static var phantomObservers: [NSObjectProtocol] = []
    private static var closingPhantoms = false

    /// SwiftUI used to realize Settings as a hidden 500×500 window after launch. Close that
    /// size if it still appears, including one restored a moment later.
    static func installPhantomGuard() {
        guard phantomObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSApplication.didBecomeActiveNotification,
        ]
        for name in names {
            phantomObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let includeVisible = note.name == NSApplication.didBecomeActiveNotification
                MainActor.assumeIsolated { () -> Void in
                    closePhantomWindows(includeVisible: includeVisible)
                }
            })
        }
        for delay in [0.4, 1.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { () -> Void in
                    closePhantomWindows(includeVisible: true)
                }
            }
        }
    }

    /// A window still at SwiftUI's default 500×500 frame. A document the user is using has already
    /// been resized to the screen, so a later pass can also drop a visible one left at that size.
    private static func closePhantomWindows(includeVisible: Bool = false) {
        if closingPhantoms || NSApp.isHidden { return }
        closingPhantoms = true
        defer { closingPhantoms = false }
        for window in NSApp.windows where isPhantom(window, includeVisible: includeVisible) {
            if let document = NSDocumentController.shared.document(for: window), document.fileURL == nil {
                document.close()
            } else {
                window.close()
            }
        }
    }

    private static func isPhantom(_ window: NSWindow, includeVisible: Bool) -> Bool {
        if window.isMiniaturized || window.isKeyWindow || window.isMainWindow { return false }
        if window is NSPanel { return false }
        if controller(for: window) != nil { return false }
        if EscapeKey.isRegistered(window) { return false }
        if window.isVisible && !includeVisible { return false }
        let size = window.frame.size
        guard abs(size.width - 500) < 2, abs(size.height - 500) < 2 else { return false }
        if window.isVisible {
            guard let document = NSDocumentController.shared.document(for: window) else { return false }
            return document.fileURL == nil
        }
        return true
    }

    /// The number of folder windows that actually opened.
    @discardableResult
    static func restore() -> Int {
        let stored = WorkspaceLibrary.shared.windows
        WorkspaceLog.restoreStarted(count: stored.count)
        var opened = 0
        for item in stored {
            if open(
                bookmark: item.bookmark,
                fresh: true,
                tabs: WorkspaceWindowState(tabs: item.tabs, activePath: item.activePath)
            ) != nil {
                opened += 1
            }
        }
        return opened
    }

    static func prepareForQuit() {
        isTerminating = true
        for controller in controllers {
            controller.session.shutdown()
        }
        persistOpenWindows()
    }

    /// Backup for Esc when the key is not already consumed by the window monitor.
    override func cancelOperation(_ sender: Any?) {
        if EscapeKey.dismissTopmost() { return }
        super.cancelOperation(sender)
    }

    private static func persistOpenWindows() {
        let stored = controllers.compactMap { controller -> PersistedWorkspaceWindow? in
            guard let data = controller.session.bookmark else { return nil }
            let bookmark = WorkspaceBookmark(id: UUID(), name: controller.session.displayName, data: data)
            return PersistedWorkspaceWindow(bookmark: bookmark, state: controller.session.windowState())
        }
        WorkspaceLibrary.shared.syncWindows(stored)
    }
}

enum WorkspaceFolders {
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        // Packages stay documents. A folder workspace is a real directory.
        if let values = try? url.resourceValues(forKeys: [.isPackageKey]), values.isPackage == true {
            return false
        }
        return true
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
                WorkspaceLog.externalOpenFolder(source: "window-drop", path: url.path)
                let bookmark = WorkspaceBookmarks.capture(url)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { () -> Void in
                        _ = WorkspaceWindowController.open(url: url, bookmark: bookmark)
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
    override init() {
        super.init()
        FolderOpening.installEarly()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppAppearance.stored.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        GutterSnapshotCheck.finishIfRequested()
        FolderOpening.installLate()
        FileMenuSupport.install()
        MainActor.assumeIsolated {
            EditorMenuSupport.install()
            EscapeKey.install()
        }
        let restored = MainActor.assumeIsolated {
            WorkspaceWindowController.restore()
        }
        if restored == 0 {
            MainActor.assumeIsolated {
                WorkspaceWindowController.reopenLastFolder()
            }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                WorkspaceWindowController.closeStrayWindows()
                WorkspaceWindowController.installPhantomGuard()
                FolderOpening.allowDocumentOpenPanels()
            }
        }
        FileMenuCheck.finishIfRequested()
        #if DEBUG
        FolderLaunchArgument.performIfRequested()
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // A Dock drop can arrive once the document controller exists. Hook it before SwiftUI opens the URL.
        FolderOpening.installLate()
        let folders = urls.filter(WorkspaceFolders.isDirectory)
        WorkspaceLog.externalOpen(source: "application-open", urlCount: urls.count, folderCount: folders.count)
        for url in folders {
            WorkspaceLog.externalOpenFolder(source: "application-open", path: url.path)
        }
        guard !folders.isEmpty else { return }
        MainActor.assumeIsolated {
            for url in folders {
                WorkspaceWindowController.open(url: url)
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        FolderOpening.installLate()
        let url = URL(fileURLWithPath: filename)
        let isFolder = WorkspaceFolders.isDirectory(url)
        WorkspaceLog.externalOpen(source: "open-file", urlCount: 1, folderCount: isFolder ? 1 : 0)
        guard isFolder else { return false }
        WorkspaceLog.externalOpenFolder(source: "open-file", path: url.path)
        MainActor.assumeIsolated { () -> Void in
            _ = WorkspaceWindowController.open(url: url)
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            WorkspaceWindowController.prepareForQuit()
        }
        return .terminateNow
    }
}

/// Fills a document or folder window to the screen's visible frame once.
///
/// This is the Option-click green button: under the menu bar and the Dock, not a full-screen space.
/// A size chosen later in the session stays. The next launch fills again, including when state
/// restoration has just put back a saved frame.
@MainActor
enum WindowFill {
    private static let filled = NSHashTable<NSWindow>.weakObjects()

    static func fillOnce(_ window: NSWindow) {
        guard !filled.contains(window) else { return }
        filled.add(window)
        apply(window)
        // Scene restoration can put a saved frame back after the first layout pass.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                apply(window)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        apply(window)
                    }
                }
            }
        }
    }

    private static func apply(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        guard window.frame != frame else { return }
        window.setFrame(frame, display: true, animate: false)
    }
}

/// First appearance of a document window. Folder windows fill from their controller.
struct WindowFillAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowFillView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowFillView: NSView {
        nonisolated override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated {
                guard let window = self.window else { return }
                WindowFill.fillOnce(window)
            }
        }
    }
}

struct WorkspaceCommands: Commands {
    @ObservedObject private var library = WorkspaceLibrary.shared

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
        }
    }
}
#endif
