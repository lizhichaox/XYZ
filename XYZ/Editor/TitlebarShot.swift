#if os(macOS)
import AppKit

/// Renders the real title bar to a PNG for design review: `-XYZCheckTitlebar`.
///
/// Screen capture needs the Screen Recording permission; drawing the window's own views
/// into a bitmap does not, so this works from a plain shell launch and shows exactly what
/// the traffic lights and the three layout buttons look like together.
enum TitlebarShot {
    static func shootIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-XYZCheckTitlebar") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            shoot()
            NSLog("TITLEBAR_SHOT done")
            if ProcessInfo.processInfo.arguments.contains("-XYZQuitAfterShot") {
                NSApp.terminate(nil)
            }
        }
    }

    private static func shoot() {
        // A window built here, not the restored one: the same chrome path, the same
        // traffic lights, and no dependency on the owner's folder being reachable.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.xyzEditor.cgColor
        window.contentView = content
        window.appearance = NSAppearance(named: .darkAqua)
        WorkspaceChrome.apply(to: window, title: "AGENTS.md — LIZHICHAO", subtitle: "", representedFile: nil)
        let installer = TitlebarTitleInstaller()
        installer.install(in: window, title: "AGENTS.md — LIZHICHAO")
        installer.updateToggles(
            sidebarShown: true,
            outlineShown: false,
            outlineEnabled: true,
            readingMode: true,
            modeEnabled: true,
            onSidebar: {},
            onOutline: {},
            onMode: {}
        )
        window.makeKeyAndOrderFront(nil)
        // The real app calls install again from the chrome view's own layout, and a
        // constraint change needs one more layout pass before it shows. Do both a few
        // times so the capture is the settled state.
        for _ in 0..<3 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            installer.install(in: window, title: "AGENTS.md — LIZHICHAO")
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        if let closeButton = window.standardWindowButton(.closeButton),
           let bar = closeButton.superview {
            for view in bar.subviews {
                NSLog("TITLEBAR_VIEW \(type(of: view)) frame=\(NSStringFromRect(view.frame))")
                for child in view.subviews {
                    NSLog("  TITLEBAR_CHILD \(type(of: child)) frame=\(NSStringFromRect(child.frame))")
                }
            }
        }
        guard let frameView = window.contentView?.superview else {
            NSLog("TITLEBAR_SHOT no frame view")
            return
        }
        // Only the title-bar strip: enough to compare the two button groups.
        let titlebarHeight = max(28, window.contentView?.frame.maxY ?? frameView.bounds.height)
        let strip = NSRect(
            x: 0,
            y: frameView.bounds.height - titlebarHeight,
            width: frameView.bounds.width,
            height: titlebarHeight
        )
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: strip) else {
            NSLog("TITLEBAR_SHOT no bitmap")
            return
        }
        frameView.cacheDisplay(in: strip, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("TITLEBAR_SHOT no png")
            return
        }
        let path = "/tmp/xyz-titlebar.png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            let left = window.standardWindowButton(.closeButton).map { frameView.convert($0.bounds, from: $0) }
            let right = window.standardWindowButton(.zoomButton).map { frameView.convert($0.bounds, from: $0) }
            NSLog("TITLEBAR_SHOT wrote \(path) strip=\(NSStringFromRect(strip)) close=\(String(describing: left)) zoom=\(String(describing: right))")
        } catch {
            NSLog("TITLEBAR_SHOT write failed \(error)")
        }
    }
}
#endif
