#if os(macOS)
import AppKit
import SwiftUI

/// Esc closes the topmost transient UI, wherever focus sits.
///
/// The field editor and `WKWebView` treat Esc as `cancelOperation:` and never forward it, so a
/// find field, the palette, or the Reading view swallows the key before a panel sees it. This
/// monitor runs before delivery. It closes one layer (a menu, a sheet, folder search, the
/// palette, the tab switcher, or a find bar) and returns focus to the editor. An input method
/// that is still composing keeps the key.
@MainActor
enum EscapeKey {
    private static var monitor: Any?
    private static var menuObservers: [NSObjectProtocol] = []
    private static weak var trackingMenu: NSMenu?
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    static func install() {
        guard monitor == nil else { return }
        watchMenus()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let closed = MainActor.assumeIsolated { () -> Bool in
                if flags.isEmpty {
                    return dismissTopmost()
                }
                // ⌃Tab is still holding Control (and maybe Shift). Esc cancels that list.
                if flags.isSubset(of: [.control, .shift]), !markedTextIsActive() {
                    return EditorCommands.shared.cancelTabSwitchIfShowing()
                }
                return false
            }
            return closed ? nil : event
        }
    }

    /// Closes one layer. Settings and About use this too, including from the window controller.
    @discardableResult
    static func dismissTopmost() -> Bool {
        if markedTextIsActive() { return false }
        let closed = dismissMenu()
            || dismissModal()
            || dismissSheet()
            || EditorCommands.shared.dismissTransient()
            || closeKeyWindow()
        if closed {
            EditorCommands.shared.focusEditor()
        }
        return closed
    }

    static func register(_ window: NSWindow) {
        windows.add(window)
    }

    static func isRegistered(_ window: NSWindow) -> Bool {
        windows.contains(window)
    }

    private static func watchMenus() {
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated { () -> Void in
                trackingMenu = note.object as? NSMenu
            }
        })
        menuObservers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { () -> Void in
                trackingMenu = nil
            }
        })
    }

    /// A composing input method uses Esc to drop the marked text. Leave that key alone.
    private static func markedTextIsActive() -> Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return text.hasMarkedText()
    }

    private static func dismissMenu() -> Bool {
        if let menu = trackingMenu, menu.highlightedItem != nil {
            menu.cancelTracking()
            trackingMenu = nil
            return true
        }
        if let menu = highlightedMenu(NSApp.mainMenu) {
            menu.cancelTracking()
            return true
        }
        var closed = false
        for window in NSApp.windows where window.isVisible && isMenuWindow(window) {
            window.orderOut(nil)
            closed = true
        }
        return closed
    }

    private static func highlightedMenu(_ menu: NSMenu?) -> NSMenu? {
        guard let menu else { return nil }
        if menu.highlightedItem != nil { return menu }
        for item in menu.items {
            if let found = highlightedMenu(item.submenu) { return found }
        }
        return nil
    }

    private static func isMenuWindow(_ window: NSWindow) -> Bool {
        let name = NSStringFromClass(type(of: window))
        return name.contains("MenuWindow") || name.contains("CarbonMenu") || name.contains("ContextMenu")
    }

    private static func dismissModal() -> Bool {
        guard NSApp.modalWindow != nil else { return false }
        NSApp.stopModal(withCode: .cancel)
        return true
    }

    private static func dismissSheet() -> Bool {
        if let key = NSApp.keyWindow, let sheet = key.attachedSheet {
            key.endSheet(sheet, returnCode: .cancel)
            return true
        }
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .cancel)
                return true
            }
        }
        return false
    }

    private static func closeKeyWindow() -> Bool {
        guard let window = NSApp.keyWindow, windows.contains(window) else { return false }
        window.performClose(nil)
        return true
    }
}

extension NSAlert {
    /// `runModal()`, with Esc choosing the last button: Cancel when there is one, OK when it is alone.
    /// AppKit only maps Esc to a button titled “Cancel”, which misses 取消 and single-button alerts.
    @MainActor
    func runModalClosingOnEscape() -> NSApplication.ModalResponse {
        let last = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + max(buttons.count - 1, 0)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: last))
            return nil
        }
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        return runModal()
    }
}

extension View {
    /// Registers the hosting window with ``EscapeKey``, for SwiftUI windows such as Settings.
    func closesOnEscape() -> some View {
        background(EscapeWindowMarker())
    }
}

private struct EscapeWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView {
        MarkerView()
    }

    func updateNSView(_ view: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                EscapeKey.register(window)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}
#endif
