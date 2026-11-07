#if os(macOS)
import AppKit

/// Removes the Markdown formatting commands.
///
/// Agents write Markdown, so the editor does not offer bold, italic, links, headings, or the
/// other Format commands. ⌘B is only Toggle Sidebar. A Format menu with nothing left is removed.
@MainActor
enum FormatMenu {
    private static let menuID = NSUserInterfaceItemIdentifier("xyz.format")
    private static let selectors: Set<String> = [
        "xyzBold:", "xyzItalic:", "xyzStrikethrough:", "xyzInlineCode:", "xyzLink:",
        "xyzQuote:", "xyzCodeBlock:", "xyzTable:", "xyzHeading:",
        "xyzBulletList:", "xyzNumberedList:", "xyzTaskList:",
    ]

    static func removeMarkdownItems(from main: NSMenu) {
        var touched: [NSMenu] = []
        strip(main, touched: &touched)
        for menu in touched {
            tidySeparators(in: menu)
        }
        let touchedMenus = Set(touched.map { ObjectIdentifier($0) })
        let empty = main.items.filter { item in
            guard let submenu = item.submenu else { return false }
            let ours = item.identifier == menuID || touchedMenus.contains(ObjectIdentifier(submenu))
            return ours && isVacant(submenu)
        }
        for item in empty {
            main.removeItem(item)
        }
    }

    private static func strip(_ menu: NSMenu, touched: inout [NSMenu]) {
        for item in menu.items {
            if let submenu = item.submenu {
                strip(submenu, touched: &touched)
            }
        }
        let remove = menu.items.filter { item in
            if let id = item.identifier?.rawValue, id.hasPrefix("xyz.format.") {
                return true
            }
            guard let action = item.action else { return false }
            return selectors.contains(NSStringFromSelector(action))
        }
        guard !remove.isEmpty else { return }
        touched.append(menu)
        for item in remove {
            menu.removeItem(item)
        }
    }

    private static func isVacant(_ menu: NSMenu?) -> Bool {
        guard let menu else { return true }
        for item in menu.items {
            if item.isSeparatorItem { continue }
            if item.submenu != nil {
                if !isVacant(item.submenu) { return false }
                continue
            }
            return false
        }
        return true
    }

    /// Drop separators that are doubled, first, or last after the Markdown items leave.
    private static func tidySeparators(in menu: NSMenu) {
        var index = 0
        var previousSeparator = true
        while index < menu.items.count {
            let item = menu.items[index]
            if item.isSeparatorItem, previousSeparator {
                menu.removeItem(at: index)
                continue
            }
            previousSeparator = item.isSeparatorItem
            index += 1
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
    }
}
#endif
