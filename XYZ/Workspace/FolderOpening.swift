#if os(macOS)
import AppKit
import ObjectiveC

/// File → Open Folder…, and the hooks that let File → Open and the Dock open a folder too.
///
/// SwiftUI's DocumentGroup owns `NSDocumentController`. Installing another controller
/// crashes `PlatformDocumentController` at launch, so these hooks run against the
/// controller SwiftUI creates. They never replace it.
enum FolderOpening {
    private static var didInstallEarly = false
    private static var didHookOpenDocument = false
    private static var didHookOpenPanel = false

    static var openDocumentHooked: Bool { didHookOpenDocument }
    static var openPanelHooked: Bool { didHookOpenPanel }

    static func installEarly() {
        guard !didInstallEarly else { return }
        didInstallEarly = true
        // Safe before DocumentGroup builds its controller: this only wraps NSSavePanel.
        hookOpenPanelPresentation()
    }

    /// Call only after SwiftUI has created `PlatformDocumentController`.
    /// Touching `NSDocumentController.shared` earlier would create the wrong controller and crash launch.
    static func installLate() {
        installEarly()
        hookOpenDocument(on: type(of: NSDocumentController.shared))
    }

    /// Document Open panel: files stay selectable, and a chosen folder becomes a workspace.
    static func prepareDocumentPanel(_ panel: NSOpenPanel) {
        guard panel.canChooseFiles else { return }
        panel.canChooseDirectories = true
        let types = panel.allowedContentTypes
        guard !types.isEmpty, !types.contains(where: { $0.conforms(to: .folder) }) else { return }
        panel.allowedContentTypes = types + [.folder]
    }

    /// NSOpenPanel shows itself through NSSavePanel. Adjust the panel at that moment,
    /// after DocumentGroup has applied its file types.
    private static func hookOpenPanelPresentation() {
        let cls: AnyClass = NSSavePanel.self
        let began = hook(cls, NSSelectorFromString("beginWithCompletionHandler:")) { original, selector in
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { panel, handler in
                if let open = panel as? NSOpenPanel {
                    prepareDocumentPanel(open)
                }
                let call = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector, AnyObject?) -> Void).self)
                call(panel, selector, handler)
            }
            return imp_implementationWithBlock(block)
        }
        let sheet = hook(cls, NSSelectorFromString("beginSheetModalForWindow:completionHandler:")) { original, selector in
            let block: @convention(block) (AnyObject, AnyObject, AnyObject?) -> Void = { panel, window, handler in
                if let open = panel as? NSOpenPanel {
                    prepareDocumentPanel(open)
                }
                let call = unsafeBitCast(
                    original,
                    to: (@convention(c) (AnyObject, Selector, AnyObject, AnyObject?) -> Void).self
                )
                call(panel, selector, window, handler)
            }
            return imp_implementationWithBlock(block)
        }
        let modal = hook(cls, NSSelectorFromString("runModal")) { original, selector in
            let block: @convention(block) (AnyObject) -> Int = { panel in
                if let open = panel as? NSOpenPanel {
                    prepareDocumentPanel(open)
                }
                let call = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector) -> Int).self)
                return call(panel, selector)
            }
            return imp_implementationWithBlock(block)
        }
        didHookOpenPanel = began || sheet || modal
    }

    private static func hookOpenDocument(on cls: AnyClass) {
        guard !didHookOpenDocument else { return }
        let sel = NSSelectorFromString("openDocumentWithContentsOfURL:display:completionHandler:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, NSURL, Bool, AnyObject) -> Void = { controller, url, display, completion in
            if WorkspaceFolders.isDirectory(url as URL) {
                let bookmark = WorkspaceBookmarks.capture(url as URL)
                let open = {
                    MainActor.assumeIsolated {
                        WorkspaceWindowController.open(url: url as URL, bookmark: bookmark)
                    }
                }
                if Thread.isMainThread {
                    open()
                } else {
                    DispatchQueue.main.async(execute: open)
                }
                let cancel = NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.userCancelled.rawValue,
                    userInfo: nil
                )
                let finish = unsafeBitCast(
                    completion,
                    to: (@convention(block) (AnyObject?, Bool, NSError?) -> Void).self
                )
                finish(nil, false, cancel)
                return
            }
            let call = unsafeBitCast(
                original,
                to: (@convention(c) (AnyObject, Selector, NSURL, Bool, AnyObject) -> Void).self
            )
            call(controller, sel, url, display, completion)
        }
        let imp = imp_implementationWithBlock(block)
        let encoding = method_getTypeEncoding(method)
        if !class_addMethod(cls, sel, imp, encoding) {
            method_setImplementation(method, imp)
        }
        didHookOpenDocument = true
    }

    @discardableResult
    private static func hook(_ cls: AnyClass, _ sel: Selector, _ make: (IMP, Selector) -> IMP) -> Bool {
        guard let method = class_getInstanceMethod(cls, sel) else { return false }
        let original = method_getImplementation(method)
        let imp = make(original, sel)
        let encoding = method_getTypeEncoding(method)
        if !class_addMethod(cls, sel, imp, encoding) {
            method_setImplementation(method, imp)
        }
        return true
    }
}

/// Always-enabled target for File → Open Folder…. SwiftUI's command can be disabled
/// when no document window is focused, which is exactly when this command is needed.
final class FolderActions: NSObject {
    static let shared = FolderActions()

    @objc func openFolder(_ sender: Any?) {
        MainActor.assumeIsolated {
            WorkspaceWindowController.prompt()
        }
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(openFolder(_:))
    }
}

enum FileMenuSupport {
    static let title = "Open Folder…"

    private static var ensuring = false
    private static var observing = false
    private static var observers: [NSObjectProtocol] = []
    private static let menuDelegate = FileMenuDelegate()

    static func install() {
        if !observing {
            observing = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { note in
                guard let menu = note.object as? NSMenu, menu === fileMenu() else { return }
                ensure(menu)
            })
            observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                guard let menu = note.object as? NSMenu, menu === fileMenu() else { return }
                adopt(menu)
                ensure(menu)
            })
        }
        if let menu = fileMenu() {
            adopt(menu)
            ensure(menu)
        }
    }

    static func report() -> (ok: Bool, summary: String) {
        install()
        guard let menu = fileMenu() else {
            return (false, "no File menu")
        }
        let titles = menu.items.map { item in
            let mark = item.isHidden ? " (hidden)" : ""
            return item.title + mark
        }
        let match = menu.items.first { $0.title == title }
        let shortcut = match.map { item in
            item.keyEquivalent.lowercased() == "o"
                && item.keyEquivalentModifierMask.contains(.command)
                && item.keyEquivalentModifierMask.contains(.shift)
        } ?? false
        let visible = match.map { !$0.isHidden && $0.target === FolderActions.shared } ?? false
        let ok = visible && shortcut
        return (ok, titles.joined(separator: " | "))
    }

    private static func fileMenu() -> NSMenu? {
        guard let items = NSApp.mainMenu?.items else { return nil }
        for item in items {
            guard let menu = item.submenu else { continue }
            let opensDocument = menu.items.contains { candidate in
                candidate.keyEquivalent.lowercased() == "o"
                    && candidate.keyEquivalentModifierMask.contains(.command)
                    && !candidate.keyEquivalentModifierMask.contains(.shift)
            }
            if opensDocument || menu.items.contains(where: { $0.title == title }) || item.title == "File" {
                return menu
            }
        }
        return nil
    }

    private static func adopt(_ menu: NSMenu) {
        if menu.delegate === menuDelegate { return }
        if let existing = menu.delegate, existing !== menuDelegate {
            menuDelegate.previous = existing
        }
        menu.delegate = menuDelegate
    }

    private static func ensure(_ menu: NSMenu) {
        if ensuring { return }
        ensuring = true
        defer { ensuring = false }

        let matches = menu.items.filter { $0.title == title }
        let item: NSMenuItem
        if let first = matches.first {
            item = first
            for extra in matches.dropFirst() {
                menu.removeItem(extra)
            }
        } else {
            let created = NSMenuItem(title: title, action: #selector(FolderActions.openFolder(_:)), keyEquivalent: "o")
            created.keyEquivalentModifierMask = [.command, .shift]
            created.target = FolderActions.shared
            menu.insertItem(created, at: indexAfterOpen(in: menu))
            item = created
        }

        item.target = FolderActions.shared
        item.action = #selector(FolderActions.openFolder(_:))
        item.keyEquivalent = "o"
        item.keyEquivalentModifierMask = [.command, .shift]
        item.isHidden = false
        item.isEnabled = true

        let destination = indexAfterOpen(in: menu)
        if let current = menu.items.firstIndex(of: item), current != destination {
            menu.removeItem(at: current)
            let adjusted = current < destination ? destination - 1 : destination
            menu.insertItem(item, at: min(adjusted, menu.items.count))
        }
    }

    private static func indexAfterOpen(in menu: NSMenu) -> Int {
        if let open = menu.items.firstIndex(where: { item in
            item.title != title
                && item.keyEquivalent.lowercased() == "o"
                && item.keyEquivalentModifierMask.contains(.command)
                && !item.keyEquivalentModifierMask.contains(.shift)
        }) {
            return open + 1
        }
        return min(1, menu.items.count)
    }
}

private final class FileMenuDelegate: NSObject, NSMenuDelegate {
    var previous: NSMenuDelegate?

    func menuNeedsUpdate(_ menu: NSMenu) {
        previous?.menuNeedsUpdate?(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        previous?.menuWillOpen?(menu)
        FileMenuSupport.install()
    }

    func menuDidClose(_ menu: NSMenu) {
        previous?.menuDidClose?(menu)
    }

    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return previous?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let previous, previous.responds(to: selector) {
            return previous
        }
        return super.forwardingTarget(for: selector)
    }
}

enum FileMenuCheck {
    static let argument = "-XYZCheckFileMenu"

    static func finishIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        poll(attempt: 0)
    }

    private static func poll(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.activate()
            FileMenuSupport.install()
            let report = FileMenuSupport.report()
            let probe = NSOpenPanel()
            probe.canChooseFiles = true
            probe.canChooseDirectories = false
            probe.allowedContentTypes = [.plainText]
            FolderOpening.prepareDocumentPanel(probe)
            let policy = probe.canChooseDirectories && probe.allowedContentTypes.contains(.folder)
            let folderOnly = NSOpenPanel()
            folderOnly.canChooseFiles = false
            folderOnly.canChooseDirectories = true
            FolderOpening.prepareDocumentPanel(folderOnly)
            let folderPanelUntouched = !folderOnly.canChooseFiles && folderOnly.canChooseDirectories
            let ready = report.ok && policy && folderPanelUntouched && FolderOpening.openPanelHooked && FolderOpening.openDocumentHooked
            if ready || attempt >= 12 {
                let line = """
                \(ready ? "FILEMENU_OK" : "FILEMENU_MISSING") \(report.summary)
                hooks panel=\(FolderOpening.openPanelHooked) document=\(FolderOpening.openDocumentHooked) policy=\(policy) folderPanel=\(folderPanelUntouched)
                """
                print(line)
                fflush(stdout)
                exit(ready ? 0 : 1)
            }
            poll(attempt: attempt + 1)
        }
    }
}
#endif
