#if os(macOS)
@preconcurrency import AppKit
import os
import SwiftUI
import XYZCore

enum ViewModeLog {
    static let logger = Logger(subsystem: "com.lizhichao.XYZ", category: "viewmode")

    static func changed(from: String, to: String, source: String) {
        logger.notice("mode changed from=\(from, privacy: .public) to=\(to, privacy: .public) source=\(source, privacy: .public)")
    }
}

enum PaletteLog {
    static let logger = Logger(subsystem: "com.lizhichao.XYZ", category: "palette")

    static func opened(files: Int, commands: Int) {
        logger.notice("opened files=\(files, privacy: .public) commands=\(commands, privacy: .public)")
    }

    static func closed() {
        logger.notice("closed")
    }

    static func ranCommand(_ id: String) {
        logger.notice("ran kind=command id=\(id, privacy: .public)")
    }

    static func ranFile() {
        logger.notice("ran kind=file")
    }
}

@MainActor
protocol EditorCommandTarget: AnyObject {
    var editorViewMode: EditorViewMode { get }
    var showsHiddenFiles: Bool { get }
    var supportsWorkspaceFiles: Bool { get }
    func editorSelect(_ mode: EditorViewMode, source: String)
    func editorToggle(source: String)
    func paletteFiles() -> [PaletteFile]
    func paletteOpen(fileID: String, newWindow: Bool)
    func toggleSidebar()
    func focusFilter()
    func toggleHiddenFiles()
    func newFile()
    func newFolder()
    func reveal()
    func copyPath()
    func reloadFile()
    func paletteHeadings() -> [OutlineHeading]
    func revealHeading(line: Int)
    func performCustomCommand(_ id: String) -> Bool
}

@MainActor
extension EditorCommandTarget {
    var showsHiddenFiles: Bool { true }
    var supportsWorkspaceFiles: Bool { false }
    func toggleSidebar() {}
    func focusFilter() {}
    func toggleHiddenFiles() {}
    func newFile() {}
    func newFolder() {}
    func reveal() {}
    func copyPath() {}
    func reloadFile() {}
    func paletteHeadings() -> [OutlineHeading] { [] }
    func revealHeading(line: Int) {}
    func performCustomCommand(_ id: String) -> Bool { false }
}

/// Menu actions and key equivalents for document windows and folder windows.
@MainActor
final class EditorCommands: NSObject {
    static let shared = EditorCommands()

    weak var target: EditorCommandTarget?
    private let palette = CommandPaletteController()

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers ?? ""
        if flags == .command && key == "/" {
            guard target != nil else { return false }
            toggleSource(nil)
            return true
        }
        if flags == .command && key.lowercased() == "p" {
            showPalette(nil)
            return true
        }
        if flags == .command && key.lowercased() == "r" {
            guard target != nil else { return false }
            goToHeading(nil)
            return true
        }
        // ⌘= is the unshifted ⌘+ on most layouts.
        if (flags == .command || flags == [.command, .shift]) && (key == "=" || key == "+") {
            zoomIn(nil)
            return true
        }
        if flags == .command && key == "-" {
            zoomOut(nil)
            return true
        }
        if flags == .command && key == "0" {
            actualSize(nil)
            return true
        }
        if flags == [.command, .shift] && key.lowercased() == "f" {
            guard target?.supportsWorkspaceFiles == true else { return false }
            focusFilter(nil)
            return true
        }
        if flags == [.command, .shift] && key == "." {
            guard target?.supportsWorkspaceFiles == true else { return false }
            toggleHidden(nil)
            return true
        }
        return false
    }

    func run(_ id: String) {
        if target?.performCustomCommand(id) == true { return }
        switch id {
        case "view.source", "view.coding":
            target?.editorSelect(.source, source: "menu")
        case "view.reading":
            target?.editorSelect(.reading, source: "menu")
        case "view.toggleSource", "view.toggleReading":
            target?.editorToggle(source: "menu")
        case "workspace.toggleSidebar":
            target?.toggleSidebar()
        case "workspace.focusFilter":
            target?.focusFilter()
        case "workspace.toggleHidden":
            target?.toggleHiddenFiles()
        case "file.new":
            target?.newFile()
        case "folder.new":
            target?.newFolder()
        case "folder.open":
            WorkspaceWindowController.prompt()
        case "file.reveal":
            target?.reveal()
        case "file.copyPath":
            target?.copyPath()
        case "file.reload":
            target?.reloadFile()
        case "view.goToHeading":
            // The palette that ran this command is closing. Open it again on the next turn.
            DispatchQueue.main.async { [weak self] in
                self?.goToHeading(nil)
            }
        case "app.about":
            AboutWindow.show()
        default:
            break
        }
    }

    @objc func showPalette(_ sender: Any?) {
        palette.show(target: target)
    }

    @objc func goToHeading(_ sender: Any?) {
        palette.show(target: target, query: "@")
    }

    @objc func zoomIn(_ sender: Any?) {
        TextZoom.step(1)
    }

    @objc func zoomOut(_ sender: Any?) {
        TextZoom.step(-1)
    }

    @objc func actualSize(_ sender: Any?) {
        TextZoom.reset()
    }

    @objc func toggleWordCount(_ sender: Any?) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: WordCountSetting.key), forKey: WordCountSetting.key)
    }

    @objc func toggleSource(_ sender: Any?) {
        target?.editorToggle(source: invocationSource())
    }

    @objc func selectSource(_ sender: Any?) {
        target?.editorSelect(.source, source: invocationSource())
    }

    @objc func selectReading(_ sender: Any?) {
        target?.editorSelect(.reading, source: invocationSource())
    }

    @objc func focusFilter(_ sender: Any?) {
        target?.focusFilter()
    }

    @objc func toggleHidden(_ sender: Any?) {
        target?.toggleHiddenFiles()
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.identifier?.rawValue {
        case "xyz.mode.source":
            menuItem.state = target?.editorViewMode == .source ? .on : .off
            return target != nil
        case "xyz.mode.reading":
            menuItem.state = target?.editorViewMode == .reading ? .on : .off
            return target != nil
        case "xyz.mode.toggleSource", "xyz.goToHeading":
            return target != nil
        case "xyz.wordCount":
            menuItem.state = UserDefaults.standard.bool(forKey: WordCountSetting.key) ? .on : .off
            return true
        case "xyz.workspace.filter":
            return target?.supportsWorkspaceFiles == true
        case "xyz.workspace.hidden":
            let shown = target?.showsHiddenFiles == true
            menuItem.title = shown ? String(localized: "Hide Hidden Files") : String(localized: "Show Hidden Files")
            return target?.supportsWorkspaceFiles == true
        case "xyz.commandPalette":
            return true
        default:
            return true
        }
    }

    private func invocationSource() -> String {
        NSApp.currentEvent?.type == .keyDown ? "shortcut" : "menu"
    }
}

/// Palette titles in the interface language. XYZCore keeps the English titles; the English
/// title stays a keyword, so typing it still finds the command in Chinese.
enum PaletteTitles {
    static func localized(_ command: PaletteCommand) -> PaletteCommand {
        guard let title = title(for: command.id), title != command.title else { return command }
        var copy = command
        copy.keywords.append(command.title)
        copy.title = title
        return copy
    }

    private static func title(for id: String) -> String? {
        switch id {
        case "view.source": return String(localized: "Source")
        case "view.reading": return String(localized: "Reading")
        case "view.toggleSource": return String(localized: "Toggle Source and Reading")
        case "view.goToHeading": return String(localized: "Go to Heading")
        case "workspace.toggleSidebar": return String(localized: "Toggle Sidebar")
        case "workspace.focusFilter": return String(localized: "Filter Files")
        case "file.new": return String(localized: "New File")
        case "folder.new": return String(localized: "New Folder")
        case "folder.open": return String(localized: "Open Folder")
        case "file.reveal": return String(localized: "Reveal in Finder")
        case "file.copyPath": return String(localized: "Copy Path")
        case "file.reload": return String(localized: "Reload")
        case "app.about": return String(localized: "About XYZ")
        default: return nil
        }
    }
}

@MainActor
enum EditorMenuSupport {
    private static var observing = false
    private static var ensuring = false
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        if !observing {
            observing = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ensure() }
            })
            observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ensure() }
            })
        }
        ensure()
    }

    private static func ensure() {
        if ensuring { return }
        ensuring = true
        defer { ensuring = false }
        guard let main = NSApp.mainMenu else { return }
        remapConflictingShortcuts(in: main)
        if let view = viewMenu(in: main) {
            ensureViewItems(in: view)
        }
        if let file = fileMenu(in: main) {
            ensureFileItems(in: file)
        }
        FormatMenu.ensure(in: main)
    }

    private static func remapConflictingShortcuts(in menu: NSMenu) {
        for item in menu.items {
            let flags = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            let key = item.keyEquivalent.lowercased()
            if isUseSelectionForFind(item) {
                item.keyEquivalent = "e"
                item.keyEquivalentModifierMask = .command
            } else if isPrint(item) {
                item.keyEquivalent = "p"
                item.keyEquivalentModifierMask = [.command, .shift, .option]
            } else if key == "p", flags == .command, item.identifier?.rawValue != "xyz.commandPalette" {
                if item.action == #selector(NSDocument.printDocument(_:)) {
                    item.keyEquivalent = "p"
                    item.keyEquivalentModifierMask = [.command, .shift, .option]
                }
            }
            if let submenu = item.submenu {
                remapConflictingShortcuts(in: submenu)
            }
        }
    }

    /// Edit → Use Selection for Find stays ⌘E. The tag distinguishes it from Find (⌘F).
    /// `performTextFinderAction` is on NSResponder. `performFindPanelAction` is on NSTextView.
    private static func isUseSelectionForFind(_ item: NSMenuItem) -> Bool {
        if item.title == "Use Selection for Find" {
            return true
        }
        if item.action == #selector(NSResponder.performTextFinderAction(_:)),
           item.tag == NSTextFinder.Action.setSearchString.rawValue {
            return true
        }
        if item.action == #selector(NSTextView.performFindPanelAction(_:)),
           item.tag == Int(NSFindPanelAction.setFindString.rawValue) {
            return true
        }
        return false
    }

    private static func ensureViewItems(in menu: NSMenu) {
        for identifier in ["xyz.mode.coding", "xyz.mode.preview", "xyz.mode.toggleReading"] {
            if let item = menu.items.first(where: { $0.identifier?.rawValue == identifier }) {
                menu.removeItem(item)
            }
        }
        let specs: [(String, String, String, NSEvent.ModifierFlags, Selector)] = [
            ("xyz.commandPalette", String(localized: "Command Palette…"), "p", .command, #selector(EditorCommands.showPalette(_:))),
            ("xyz.goToHeading", String(localized: "Go to Heading…"), "r", .command, #selector(EditorCommands.goToHeading(_:))),
            ("xyz.mode.source", String(localized: "Source"), "", [], #selector(EditorCommands.selectSource(_:))),
            ("xyz.mode.reading", String(localized: "Reading"), "", [], #selector(EditorCommands.selectReading(_:))),
            ("xyz.mode.toggleSource", String(localized: "Source Code Mode"), "/", .command, #selector(EditorCommands.toggleSource(_:))),
            ("xyz.zoomIn", String(localized: "Zoom In"), "+", .command, #selector(EditorCommands.zoomIn(_:))),
            ("xyz.zoomOut", String(localized: "Zoom Out"), "-", .command, #selector(EditorCommands.zoomOut(_:))),
            ("xyz.actualSize", String(localized: "Actual Size"), "0", .command, #selector(EditorCommands.actualSize(_:))),
            ("xyz.wordCount", String(localized: "Show Word Count"), "", [], #selector(EditorCommands.toggleWordCount(_:))),
        ]
        var previous: NSMenuItem?
        for spec in specs {
            if spec.0 == "xyz.mode.source" {
                previous = divider(after: previous, in: menu, identifier: "xyz.mode.divider")
            }
            if spec.0 == "xyz.mode.toggleSource" {
                previous = divider(after: previous, in: menu, identifier: "xyz.mode.toggleDivider")
            }
            if spec.0 == "xyz.zoomIn" {
                previous = divider(after: previous, in: menu, identifier: "xyz.zoom.divider")
            }
            if spec.0 == "xyz.wordCount" {
                previous = divider(after: previous, in: menu, identifier: "xyz.wordCount.divider")
            }
            let item = item(
                identifier: spec.0,
                title: spec.1,
                key: spec.2,
                flags: spec.3,
                action: spec.4,
                in: menu
            )
            place(item, after: previous, in: menu)
            previous = item
        }
    }

    private static func ensureFileItems(in menu: NSMenu) {
        let filter = item(
            identifier: "xyz.workspace.filter",
            title: String(localized: "Filter Files"),
            key: "f",
            flags: [.command, .shift],
            action: #selector(EditorCommands.focusFilter(_:)),
            in: menu
        )
        let hidden = item(
            identifier: "xyz.workspace.hidden",
            title: String(localized: "Hide Hidden Files"),
            key: ".",
            flags: [.command, .shift],
            action: #selector(EditorCommands.toggleHidden(_:)),
            in: menu
        )
        let anchor = menu.items.first { $0.title == FileMenuSupport.title }
        if let anchor, let index = menu.items.firstIndex(of: anchor) {
            move(filter, to: min(index + 1, menu.items.count), in: menu)
            move(hidden, to: min((menu.items.firstIndex(of: filter) ?? index) + 1, menu.items.count), in: menu)
        }
    }

    private static func item(
        identifier: String,
        title: String,
        key: String,
        flags: NSEvent.ModifierFlags,
        action: Selector,
        in menu: NSMenu
    ) -> NSMenuItem {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let existing = menu.items.first { $0.identifier == id }
        let item = existing ?? NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.identifier = id
        if existing == nil || identifier != "xyz.workspace.hidden" {
            item.title = title
        }
        item.action = action
        item.target = EditorCommands.shared
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = flags
        item.isHidden = false
        if item.menu == nil {
            menu.addItem(item)
        }
        return item
    }

    private static func divider(after previous: NSMenuItem?, in menu: NSMenu, identifier: String) -> NSMenuItem {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let item = menu.items.first { $0.identifier == id } ?? NSMenuItem.separator()
        item.identifier = id
        if item.menu == nil {
            menu.addItem(item)
        }
        place(item, after: previous, in: menu)
        return item
    }

    private static func place(_ item: NSMenuItem, after previous: NSMenuItem?, in menu: NSMenu) {
        let destination: Int
        if let previous, let index = menu.items.firstIndex(of: previous) {
            destination = index + 1
        } else {
            destination = 0
        }
        move(item, to: destination, in: menu)
    }

    private static func move(_ item: NSMenuItem, to destination: Int, in menu: NSMenu) {
        guard let current = menu.items.firstIndex(of: item) else { return }
        let limited = min(destination, menu.items.count)
        if current == limited || current + 1 == limited { return }
        menu.removeItem(at: current)
        let adjusted = current < limited ? limited - 1 : limited
        menu.insertItem(item, at: min(adjusted, menu.items.count))
    }

    /// Found by what it holds, not its title, which is 显示 in Chinese.
    private static func viewMenu(in main: NSMenu) -> NSMenu? {
        let menus = main.items.compactMap(\.submenu)
        if let ours = menus.first(where: { $0.items.contains { $0.identifier?.rawValue == "xyz.mode.source" } }) {
            return ours
        }
        let viewOnly = ["toggleTabBar:", "toggleTabOverview:", "toggleToolbarShown:", "toggleSidebar:"].map(NSSelectorFromString)
        if let found = menus.first(where: { menu in
            menu.items.contains { item in item.action.map { viewOnly.contains($0) } ?? false }
        }) {
            return found
        }
        let fullScreen = NSSelectorFromString("toggleFullScreen:")
        if let found = menus.first(where: { $0.items.contains { $0.action == fullScreen } }) {
            return found
        }
        return main.items.first { $0.title == "View" || $0.title == String(localized: "View") }?.submenu
    }

    /// The menu with Open… (⌘O) or Open Folder…, in any language.
    private static func fileMenu(in menu: NSMenu) -> NSMenu? {
        menu.items.compactMap(\.submenu).first { submenu in
            submenu.items.contains { item in
                item.title == FileMenuSupport.title
                    || item.action == #selector(NSDocumentController.openDocument(_:))
                    || (item.keyEquivalent.lowercased() == "o" && item.keyEquivalentModifierMask == .command)
            }
        }
    }

    private static func isPrint(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(NSDocument.printDocument(_:)) || item.action == NSSelectorFromString("print:") {
            return true
        }
        return item.title == "Print…" || item.title == "Print" || item.title == String(localized: "Print…")
    }
}

struct EditorCommandAnchor<Target: EditorCommandTarget>: NSViewRepresentable {
    var target: Target
    var prepare: () -> Void

    func makeNSView(context: Context) -> EditorAnchorView {
        EditorAnchorView()
    }

    func updateNSView(_ view: EditorAnchorView, context: Context) {
        prepare()
        view.target = target
        view.sync()
    }
}

@MainActor
final class EditorAnchorView: NSView {
    weak var target: EditorCommandTarget?
    private var observer: NSObjectProtocol?

    nonisolated override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            self.connect()
        }
    }

    nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    nonisolated override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    private func connect() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let window else { return }
        window.backgroundColor = .textBackgroundColor
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sync()
            }
        }
        sync()
    }

    func sync() {
        guard let target, window?.isKeyWindow == true else { return }
        EditorCommands.shared.target = target
    }
}

@MainActor
enum AboutWindow {
    private static var panel: AboutPanel?
    private static let links = AboutLinkHandler()

    static func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func make() -> AboutPanel {
        let panel = AboutPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 228),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "About XYZ")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let content = panel.contentView ?? NSView()

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityLabel(String(localized: "Application icon"))

        let version = NSTextField(labelWithString: versionLine())
        version.alignment = .center
        version.font = .systemFont(ofSize: 13)
        version.textColor = .secondaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false

        let credit = NSTextView()
        credit.drawsBackground = false
        credit.isEditable = false
        credit.isSelectable = true
        credit.textContainerInset = .zero
        credit.textContainer?.lineFragmentPadding = 0
        credit.textStorage?.setAttributedString(creditLine())
        credit.delegate = links
        credit.translatesAutoresizingMaskIntoConstraints = false
        credit.setAccessibilityLabel(creditLine().string)

        content.addSubview(icon)
        content.addSubview(version)
        content.addSubview(credit)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            version.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            version.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            version.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            credit.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 4),
            credit.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            credit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            credit.heightAnchor.constraint(equalToConstant: 32),
        ])
        return panel
    }

    private static func versionLine() -> String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.3"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "5"
        return "\(short) (\(build))"
    }

    private static func creditLine() -> NSAttributedString {
        let line = String(localized: "Made by LIZHICHAO with 💗")
        let text = line as NSString
        let attributed = NSMutableAttributedString(string: line)
        let full = NSRange(location: 0, length: text.length)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: full)
        attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: full)
        attributed.addAttribute(.paragraphStyle, value: style, range: full)
        let name = text.range(of: "LIZHICHAO")
        if name.location != NSNotFound, let url = URL(string: "https://lizhichao.com") {
            attributed.addAttribute(.link, value: url, range: name)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: name)
            attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: name)
        }
        return attributed
    }
}

private final class AboutPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            performClose(nil)
            return
        }
        super.keyDown(with: event)
    }
}

private final class AboutLinkHandler: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}

@MainActor
final class CommandPaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private var panel: PalettePanel?
    private var search: NSSearchField?
    private var table: NSTableView?
    private var empty: NSTextField?
    private weak var target: EditorCommandTarget?
    private var registry = PaletteCommandRegistry(commands: PaletteCommand.builtIn.map(PaletteTitles.localized))
    private var rows: [PaletteRow] = []
    /// The note's headings, read once per show the first time the query starts with `@`.
    private var headings: [OutlineHeading]?
    private var suppressResign = false
    private var closing = false

    func show(target: EditorCommandTarget?, query: String = "") {
        self.target = target
        headings = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        search?.stringValue = query
        reloadRows()
        place(panel)
        suppressResign = true
        panel.makeKeyAndOrderFront(nil)
        if let search {
            panel.makeFirstResponder(search)
        }
        let files = target?.paletteFiles().count ?? 0
        PaletteLog.opened(files: files, commands: registry.commands.count)
        DispatchQueue.main.async { [weak self] in
            self?.suppressResign = false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !suppressResign else { return }
        close()
    }

    func controlTextDidChange(_ notification: Notification) {
        reloadRows()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveDownAndModifySelection(_:)) {
            move(1)
            return true
        }
        if selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveUpAndModifySelection(_:)) {
            move(-1)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            run(newWindow: flags.contains(.command))
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PaletteCell.identifier, owner: self) as? PaletteCell ?? PaletteCell()
        guard rows.indices.contains(row) else { return cell }
        switch rows[row] {
        case .file(let file, let match):
            let title = file.relativePath.isEmpty ? file.name : file.relativePath
            cell.apply(title: highlighted(title, indices: match.characterIndices, dimDirectory: true), shortcut: "")
        case .command(let command, let match):
            cell.apply(title: highlighted(command.title, indices: match.characterIndices, dimDirectory: false), shortcut: command.shortcut)
        case .heading(let heading, let match):
            // Deeper headings step in, so the list reads as an outline.
            let indent = String(repeating: "    ", count: max(0, min(heading.level, 6) - 1))
            let offset = indent.count
            cell.apply(
                title: highlighted(indent + heading.title, indices: match.characterIndices.map { $0 + offset }, dimDirectory: false),
                shortcut: "H\(heading.level)"
            )
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let existing = tableView.makeView(withIdentifier: PaletteRowView.identifier, owner: self) as? PaletteRowView
        return existing ?? PaletteRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 280),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.title = String(localized: "Command Palette")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let search = NSSearchField()
        search.placeholderString = String(localized: "Go to file, > for commands, @ for headings")
        search.delegate = self
        search.controlSize = .regular
        search.focusRingType = .none
        search.setContentHuggingPriority(.required, for: .vertical)
        search.setContentCompressionResistancePriority(.required, for: .vertical)
        search.translatesAutoresizingMaskIntoConstraints = false
        search.setAccessibilityLabel(String(localized: "Command Palette"))
        self.search = search

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        self.table = table

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let empty = NSTextField(labelWithString: String(localized: "No matches"))
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        self.empty = empty

        let stack = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addSubview(search)
        stack.addSubview(scroll)
        stack.addSubview(empty)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: stack.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        let host = paletteBackground(content: stack)
        panel.contentView = host
        return panel
    }

    private func paletteBackground(content: NSView) -> NSView {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if #available(macOS 26, *), !reduceTransparency, !increaseContrast {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 16
            glass.style = .regular
            content.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = content
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                content.topAnchor.constraint(equalTo: glass.topAnchor),
                content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    private func reloadRows() {
        let query = search?.stringValue ?? ""
        if query.hasPrefix("@"), headings == nil {
            headings = target?.paletteHeadings() ?? []
        }
        rows = CommandPalette.rows(
            rawQuery: query,
            files: target?.paletteFiles() ?? [],
            registry: registry,
            headings: headings ?? []
        )
        empty?.isHidden = !rows.isEmpty
        table?.reloadData()
        if rows.isEmpty {
            table?.deselectAll(nil)
        } else {
            table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        resize()
    }

    private func resize() {
        guard let panel else { return }
        let list = min(CGFloat(max(rows.count, 1)) * 34, 360)
        let height = 12 + 28 + 8 + list + 8
        let width: CGFloat = 600
        var frame = panel.frame
        frame.size = NSSize(width: width, height: height)
        panel.setFrame(frame, display: true)
        place(panel)
    }

    private func place(_ panel: NSWindow) {
        let parent = NSApp.keyWindow.flatMap { $0 === panel ? $0.parent : $0 } ?? NSApp.mainWindow
        guard let parent, parent !== panel else {
            panel.center()
            return
        }
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        let width = panel.frame.width
        let height = panel.frame.height
        let origin = NSPoint(
            x: parent.frame.midX - width / 2,
            y: parent.frame.maxY - height - 64
        )
        panel.setFrameOrigin(origin)
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty, let table else { return }
        let next: Int
        if table.selectedRow < 0 {
            next = delta > 0 ? 0 : rows.count - 1
        } else {
            next = min(max(0, table.selectedRow + delta), rows.count - 1)
        }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func openSelected(_ sender: Any?) {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        run(newWindow: flags.contains(.command))
    }

    private func run(newWindow: Bool) {
        guard let table, rows.indices.contains(table.selectedRow) else { return }
        let row = rows[table.selectedRow]
        let target = self.target
        close()
        switch row {
        case .file(let file, _):
            PaletteLog.ranFile()
            target?.paletteOpen(fileID: file.relativePath, newWindow: newWindow)
        case .command(let command, _):
            PaletteLog.ranCommand(command.id)
            EditorCommands.shared.run(command.id)
        case .heading(let heading, _):
            PaletteLog.ranCommand("heading")
            target?.revealHeading(line: heading.line)
        }
    }

    private func close() {
        guard !closing, let panel, panel.isVisible else { return }
        closing = true
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        closing = false
        PaletteLog.closed()
    }

    private func highlighted(_ string: String, indices: [Int], dimDirectory: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        if dimDirectory {
            let ns = string as NSString
            let slash = ns.range(of: "/", options: .backwards)
            if slash.location != NSNotFound {
                text.addAttribute(
                    .foregroundColor,
                    value: NSColor.tertiaryLabelColor,
                    range: NSRange(location: 0, length: NSMaxRange(slash))
                )
            }
        }
        let emphasis = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let wanted = Set(indices)
        var location = 0
        for (offset, character) in string.enumerated() {
            let piece = String(character) as NSString
            if wanted.contains(offset) {
                text.addAttributes([
                    .foregroundColor: NSColor.labelColor,
                    .font: emphasis,
                ], range: NSRange(location: location, length: piece.length))
            }
            location += piece.length
        }
        return text
    }
}

/// Grey selection, so the palette stays in the black, white, and grey range.
private final class PaletteRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("xyz.palette.row")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }
}

private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            orderOut(nil)
            return
        }
        super.keyDown(with: event)
    }
}

private final class PaletteCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("xyz.palette.cell")
    private let titleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.alignment = .right
        shortcutField.font = .systemFont(ofSize: 12)
        shortcutField.textColor = .secondaryLabelColor
        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.setContentHuggingPriority(.required, for: .horizontal)
        shortcutField.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(titleField)
        addSubview(shortcutField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 12),
            shortcutField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcutField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(title: NSAttributedString, shortcut: String) {
        titleField.attributedStringValue = title
        shortcutField.stringValue = shortcut
        shortcutField.isHidden = shortcut.isEmpty
    }
}
#endif
