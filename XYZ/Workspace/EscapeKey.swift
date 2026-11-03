#if os(macOS)
import AppKit
import SwiftUI

/// Esc closes every window XYZ shows on top of a document: Settings (⌘,) and About.
///
/// One local key monitor checks the key window against the windows registered here, so Esc
/// works wherever focus sits inside them, including a picker or the selectable credit line.
/// The command palette, the Reading find bar, the sidebar filter, and the system's open panels
/// already handle Esc themselves. Alerts use ``NSAlert/runModalClosingOnEscape()``.
@MainActor
enum EscapeKey {
    private static var monitor: Any?
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }
            let closed = MainActor.assumeIsolated { closeKeyWindow() }
            return closed ? nil : event
        }
    }

    private static func closeKeyWindow() -> Bool {
        guard let window = NSApp.keyWindow, windows.contains(window) else { return false }
        window.performClose(nil)
        return true
    }

    static func register(_ window: NSWindow) {
        windows.add(window)
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
