#if os(macOS)
import AppKit

/// Offscreen check that Editing draws line numbers. CI launches the app with `-XYZCheckGutter`.
enum GutterSnapshotCheck {
    static let argument = "-XYZCheckGutter"

    static func finishIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        let failure = renderEditingGutter()
        if let failure {
            print("GUTTER_MISSING \(failure)")
        } else {
            print("GUTTER_OK")
        }
        fflush(stdout)
        exit(failure == nil ? 0 : 1)
    }

    /// Renders an editor in Editing and counts ink in the gutter. Nil means the numbers painted.
    static func renderEditingGutter() -> String? {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = false
        let textView = XYZMacTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = NSSize(width: 48, height: 8)
        textView.string = "alpha\nbeta\ngamma\ndelta\nepsilon\n"
        // Same view, flag flipped after creation: Editing on a tab that is already open.
        textView.syncLineNumbers(false)
        textView.syncLineNumbers(true)
        textView.isEditable = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.layoutIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        textView.syncLineNumbers(true)
        scroll.displayIfNeeded()

        guard let gutter = textView.lineNumberGutter else {
            return "gutter is not in the hierarchy"
        }
        guard gutter.frame.width > 8, gutter.frame.height > 8 else {
            return "gutter frame is \(NSStringFromRect(gutter.frame))"
        }
        guard gutter.superview === scroll else {
            return "gutter is not above the clip view"
        }
        guard textView.textLayoutManager != nil else {
            return "text view is not TextKit 2"
        }

        let bounds = scroll.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(bounds.width)),
            pixelsHigh: max(1, Int(bounds.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return "could not allocate a bitmap"
        }
        scroll.cacheDisplay(in: bounds, to: rep)

        // The gutter is the left strip. Sample the full height so a flipped bitmap still counts.
        var sample = gutter.convert(gutter.bounds, to: scroll)
        sample.origin.y = 0
        sample.size.height = bounds.height
        let ink = nonBackgroundPixels(in: rep, rect: sample)
        if ink < 40 {
            return "gutter region has \(ink) non-background pixels in \(NSStringFromRect(sample))"
        }
        return nil
    }

    private static func nonBackgroundPixels(in rep: NSBitmapImageRep, rect: NSRect) -> Int {
        let background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)
        var count = 0
        let minX = max(0, Int(rect.minX.rounded(.up)))
        let maxX = min(rep.pixelsWide, Int(rect.maxX.rounded(.down)))
        let minY = max(0, Int(rect.minY.rounded(.up)))
        let maxY = min(rep.pixelsHigh, Int(rect.maxY.rounded(.down)))
        guard minX < maxX, minY < maxY else { return 0 }
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let distance = abs(color.redComponent - (background?.redComponent ?? 1))
                    + abs(color.greenComponent - (background?.greenComponent ?? 1))
                    + abs(color.blueComponent - (background?.blueComponent ?? 1))
                if distance > 0.2 {
                    count += 1
                }
            }
        }
        return count
    }
}
#endif
