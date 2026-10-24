#if os(macOS)
import AppKit
import XYZCore

/// Format menu actions on the Markdown editor.
///
/// The menu items have no target, so AppKit sends them down the responder chain: they are
/// enabled only while a Markdown editor has focus, and dimmed in Reading and in plain text.
extension XYZMacTextView {
    @objc func xyzBold(_ sender: Any?) { format(SourceEditing.toggleBold) }
    @objc func xyzItalic(_ sender: Any?) { format(SourceEditing.toggleItalic) }
    @objc func xyzStrikethrough(_ sender: Any?) { format(SourceEditing.toggleStrikethrough) }
    @objc func xyzInlineCode(_ sender: Any?) { format(SourceEditing.toggleInlineCode) }
    @objc func xyzLink(_ sender: Any?) { format(SourceEditing.insertLink) }
    @objc func xyzQuote(_ sender: Any?) { format(SourceEditing.toggleQuote) }
    @objc func xyzCodeBlock(_ sender: Any?) { format(SourceEditing.insertCodeBlock) }
    @objc func xyzTable(_ sender: Any?) { format(SourceEditing.insertTable) }

    /// The menu item's tag is the level. 0 is Paragraph.
    @objc func xyzHeading(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? 0
        format { SourceEditing.setHeading(level: level, in: $0, selection: $1) }
    }

    @objc func xyzBulletList(_ sender: Any?) { format { SourceEditing.toggleList(.bullet, in: $0, selection: $1) } }
    @objc func xyzNumberedList(_ sender: Any?) { format { SourceEditing.toggleList(.ordered, in: $0, selection: $1) } }
    @objc func xyzTaskList(_ sender: Any?) { format { SourceEditing.toggleList(.task, in: $0, selection: $1) } }

    private func format(_ edit: (String, SourceRange) -> SourceReplacement?) {
        applyMarkupEdit(edit(string, sourceSelection()))
    }
}

/// Builds the Format menu and maps its shortcuts.
///
/// Shortcuts follow Typora where macOS leaves them free. Headings are ⌥⌘1 to ⌥⌘6 because
/// ⌘1 to ⌘9 stay with window tabs; strikethrough is ⇧⌘X.
@MainActor
enum FormatMenu {
    struct Item {
        var id: String
        var title: String
        var key: String
        var flags: NSEvent.ModifierFlags
        var action: Selector
        var tag = 0

        func menuItem() -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.identifier = NSUserInterfaceItemIdentifier(id)
            item.tag = tag
            item.target = nil
            return item
        }
    }

    /// Groups of items, drawn with separators between them.
    static var sections: [[Item]] {
        [
            [
                Item(id: "xyz.format.bold", title: String(localized: "Bold"), key: "b", flags: .command,
                     action: #selector(XYZMacTextView.xyzBold(_:))),
                Item(id: "xyz.format.italic", title: String(localized: "Italic"), key: "i", flags: .command,
                     action: #selector(XYZMacTextView.xyzItalic(_:))),
                Item(id: "xyz.format.strikethrough", title: String(localized: "Strikethrough"), key: "x",
                     flags: [.command, .shift], action: #selector(XYZMacTextView.xyzStrikethrough(_:))),
                Item(id: "xyz.format.code", title: String(localized: "Inline Code"), key: "`", flags: .control,
                     action: #selector(XYZMacTextView.xyzInlineCode(_:))),
                Item(id: "xyz.format.link", title: String(localized: "Link"), key: "k", flags: .command,
                     action: #selector(XYZMacTextView.xyzLink(_:))),
            ],
            [
                Item(id: "xyz.format.quote", title: String(localized: "Quote"), key: "q", flags: [.command, .option],
                     action: #selector(XYZMacTextView.xyzQuote(_:))),
                Item(id: "xyz.format.bullets", title: String(localized: "Bulleted List"), key: "u",
                     flags: [.command, .option], action: #selector(XYZMacTextView.xyzBulletList(_:))),
                Item(id: "xyz.format.numbers", title: String(localized: "Numbered List"), key: "o",
                     flags: [.command, .option], action: #selector(XYZMacTextView.xyzNumberedList(_:))),
                Item(id: "xyz.format.tasks", title: String(localized: "Task List"), key: "x",
                     flags: [.command, .option], action: #selector(XYZMacTextView.xyzTaskList(_:))),
            ],
            [
                Item(id: "xyz.format.codeBlock", title: String(localized: "Code Block"), key: "c",
                     flags: [.command, .option], action: #selector(XYZMacTextView.xyzCodeBlock(_:))),
                Item(id: "xyz.format.table", title: String(localized: "Table"), key: "", flags: [],
                     action: #selector(XYZMacTextView.xyzTable(_:))),
            ],
        ]
    }

    static var headings: [Item] {
        var items = [
            Item(id: "xyz.format.paragraph", title: String(localized: "Paragraph"), key: "0",
                 flags: [.command, .option], action: #selector(XYZMacTextView.xyzHeading(_:)), tag: 0),
        ]
        for level in 1...6 {
            items.append(Item(
                id: "xyz.format.h\(level)",
                title: String(localized: "Heading \(level)"),
                key: String(level),
                flags: [.command, .option],
                action: #selector(XYZMacTextView.xyzHeading(_:)),
                tag: level
            ))
        }
        return items
    }

    static let actions: Set<Selector> = Set((sections.flatMap { $0 } + headings).map(\.action))

    private static let shortcuts: [Item] = (sections.flatMap { $0 } + headings).filter { !$0.key.isEmpty }

    /// The item whose shortcut this key event is, if any.
    static func item(matching event: NSEvent) -> Item? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
        return shortcuts.first { $0.key == key && $0.flags == flags }
    }

    private static let menuID = NSUserInterfaceItemIdentifier("xyz.format")
    private static let headingID = NSUserInterfaceItemIdentifier("xyz.format.heading")

    /// Adds the Markdown section to the Format menu, creating the menu after Edit when SwiftUI has none.
    static func ensure(in main: NSMenu) {
        let menu = existingMenu(in: main) ?? makeMenu(in: main)
        guard !menu.items.contains(where: { $0.identifier == headingID }) else { return }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        for (index, section) in sections.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for item in section {
                menu.addItem(item.menuItem())
            }
            if index == 0 {
                let heading = NSMenuItem(title: String(localized: "Heading"), action: nil, keyEquivalent: "")
                heading.identifier = headingID
                let submenu = NSMenu(title: heading.title)
                for item in headings {
                    submenu.addItem(item.menuItem())
                }
                heading.submenu = submenu
                menu.addItem(heading)
            }
        }
    }

    private static func existingMenu(in main: NSMenu) -> NSMenu? {
        if let ours = main.items.first(where: { $0.identifier == menuID })?.submenu {
            return ours
        }
        // SwiftUI's Format menu holds the Font and Text submenus.
        let fontPanel = NSSelectorFromString("orderFrontFontPanel:")
        return main.items.compactMap(\.submenu).first { menu in
            menu.items.contains { item in
                item.submenu?.items.contains { $0.action == fontPanel } == true
            }
        }
    }

    private static func makeMenu(in main: NSMenu) -> NSMenu {
        let title = String(localized: "Format")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = menuID
        let menu = NSMenu(title: title)
        item.submenu = menu
        let undo = NSSelectorFromString("undo:")
        let edit = main.items.firstIndex { $0.submenu?.items.contains { $0.action == undo } == true }
        main.insertItem(item, at: min((edit ?? 1) + 1, main.items.count))
        return menu
    }
}
#endif
