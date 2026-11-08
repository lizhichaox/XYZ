#if os(macOS)
import AppKit

/// Drives the sidebar toggle faster than its own animation and measures how far the
/// column jumps between samples: `-XYZCheckSplit`.
enum SplitJitterCheck {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-XYZCheckSplit") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            run()
        }
    }

    private static func run() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let split = XYZSplitView()
        split.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = split
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        let detail = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let outline = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        window.makeKeyAndOrderFront(nil)
        split.install(
            sidebar: sidebar,
            detail: detail,
            outline: outline,
            showsSidebar: true,
            showsOutline: false,
            outlineWidth: 220
        )
        split.layoutSubtreeIfNeeded()

        var samples: [(CFTimeInterval, CGFloat)] = []
        let sampler = Timer(timeInterval: 0.004, repeats: true) { _ in
            samples.append((CACurrentMediaTime(), split.detailWidth))
        }
        RunLoop.main.add(sampler, forMode: .common)

        // Press faster than the 180 ms ease, the way a held-down ⌘B behaves.
        var shown = true
        var step = 0
        var presser: Timer?
        presser = Timer(timeInterval: 0.05, repeats: true) { timer in
            shown.toggle()
            let before = split.detailWidth
            split.setSidebarShown(shown)
            NSLog("SPLIT_PRESS wanted=\(shown) before=\(String(format: "%.1f", before)) after=\(String(format: "%.1f", split.detailWidth))")
            step += 1
            if step >= 16 {
                timer.invalidate()
                presser = nil
            }
        }
        RunLoop.main.add(presser!, forMode: .common)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            sampler.invalidate()
            presser?.invalidate()
            var maxJump: CGFloat = 0
            var reversals = 0
            var previous: CGFloat?
            var direction: CGFloat = 0
            for (_, width) in samples {
                if let previous, abs(width - previous) > 0.5 {
                    let step = width - previous
                    if abs(step) > maxJump { maxJump = abs(step) }
                    let sign: CGFloat = step > 0 ? 1 : -1
                    if direction != 0, sign != direction { reversals += 1 }
                    direction = sign
                }
                previous = width
            }
            let finalWidth = split.detailWidth
            NSLog("SPLIT_CHECK samples=\(samples.count) maxStep=\(String(format: "%.1f", maxJump)) reversals=\(reversals) finalDetail=\(String(format: "%.0f", finalWidth))")
            // An isolated press must still animate fully: one hide, then one show.
            split.setSidebarShown(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let afterHide = split.detailWidth
                split.setSidebarShown(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let afterShow = split.detailWidth
                    NSLog("SPLIT_SINGLE hideDetail=\(String(format: "%.0f", afterHide)) showDetail=\(String(format: "%.0f", afterShow))")
                    if ProcessInfo.processInfo.arguments.contains("-XYZQuitAfterShot") {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}
#endif
