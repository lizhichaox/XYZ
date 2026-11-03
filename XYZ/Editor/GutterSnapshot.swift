#if os(macOS)
import AppKit

/// Offscreen check that Editing draws line numbers. CI launches the app with `-XYZCheckGutter`.
enum GutterSnapshotCheck {
    static let argument = "-XYZCheckGutter"

    static func finishIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        stage("render")
        let rendered = renderEditingGutter()
        stage(rendered == nil ? "search" : "render-failed")
        let failure = rendered ?? SearchTypingCheck.run()
        stage("done")
        if let failure {
            print("GUTTER_MISSING \(failure)")
        } else {
            print("GUTTER_OK")
        }
        fflush(stdout)
        exit(failure == nil ? 0 : 1)
    }

    private static func stage(_ name: String) {
        print("GUTTER_STAGE \(name)")
        fflush(stdout)
    }

    /// Renders Reading and Editing in light and dark. Nil means glyphs and, in Editing, gutter digits painted.
    static func renderEditingGutter() -> String? {
        for name in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            if let failure = render(appearance: name, editing: false) { return failure }
            if let failure = render(appearance: name, editing: true) { return failure }
        }
        return nil
    }

    private static func render(appearance name: NSAppearance.Name, editing: Bool) -> String? {
        let appearance = NSAppearance(named: name) ?? NSAppearance(named: .aqua)!
        let mode = editing ? "editing" : "reading"
        let label = "\(name.rawValue) \(mode)"
        let pane = EditorPane(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let scroll = pane.scrollView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        scroll.contentView.drawsBackground = false
        let textView = XYZMacTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.clipsToBounds = true
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        pane.attach(textView)
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 48, height: 8)
        textView.string = "alpha\nbeta\ngamma\ndelta\nepsilon\n"
        let storage = textView.string as NSString
        textView.textStorage?.setAttributes([
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.labelColor,
        ], range: NSRange(location: 0, length: storage.length))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        scroll.appearance = appearance
        textView.appearance = appearance
        window.contentView = pane
        // Same view, flag flipped after creation: Editing on a tab that is already open.
        textView.syncLineNumbers(false)
        if editing {
            textView.syncLineNumbers(true)
            textView.isEditable = true
        }
        window.layoutIfNeeded()
        pane.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        textView.showViewport()
        if editing {
            textView.syncLineNumbers(true)
        }
        pane.layoutSubtreeIfNeeded()
        pane.gutter.needsDisplay = true
        window.displayIfNeeded()
        pane.displayIfNeeded()

        guard textView.textLayoutManager != nil else {
            return "\(label): text view is not TextKit 2"
        }
        if scroll.contentView.drawsBackground {
            return "\(label): clip view draws over the text"
        }
        let bounds = pane.bounds
        guard textView.frame.height > 8, textView.frame.width > 8 else {
            return "\(label): text view frame is \(NSStringFromRect(textView.frame))"
        }

        var textSample = NSRect(x: 64, y: 8, width: bounds.width - 80, height: bounds.height - 16)
        if editing {
            guard let gutter = textView.lineNumberGutter else {
                return "\(label): gutter is not in the hierarchy"
            }
            guard gutter.frame.width > 8, gutter.frame.height > 8 else {
                return "\(label): gutter frame is \(NSStringFromRect(gutter.frame))"
            }
            guard gutter.superview === pane, gutter.superview !== scroll else {
                return "\(label): gutter must sit beside the scroll view, not inside it"
            }
            guard gutter.frame.maxX + 16 < bounds.width else {
                return "\(label): gutter covers the text \(NSStringFromRect(gutter.frame))"
            }
            textSample.origin.x = gutter.frame.maxX + 4
            textSample.size.width = bounds.width - textSample.origin.x - 8
        }

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
            return "\(label): could not allocate a bitmap"
        }
        let background = backgroundColor(appearance)
        // TextKit 2 draws glyphs in fragment views. `cacheDisplay` on the scroll view does not
        // include them, so the glyphs are drawn from the layout fragments into their own bitmap.
        let textInk = glyphPixels(in: textView, appearance: appearance, background: background)
        if textInk < 40 {
            return "\(label): text area has \(textInk) glyph pixels in \(NSStringFromRect(textSample))"
        }
        appearance.performAsCurrentDrawingAppearance {
            pane.cacheDisplay(in: bounds, to: rep)
        }
        if editing, let gutter = textView.lineNumberGutter {
            let sample = gutter.convert(gutter.bounds, to: pane)
            let ink = nonBackgroundPixels(in: rep, rect: sample, background: background)
            if ink < 40 {
                return "\(label): gutter region has \(ink) non-background pixels in \(NSStringFromRect(sample))"
            }
        }
        return nil
    }

    /// Glyphs from the laid-out fragments. The scroll view's own snapshot does not include them.
    private static func glyphPixels(in textView: XYZMacTextView, appearance: NSAppearance, background: NSColor) -> Int {
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { return 0 }
        let viewport = manager.textViewportLayoutController
        viewport.layoutViewport()
        let size = textView.bounds.size
        guard size.width > 1, size.height > 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(1, Int(size.width)),
                pixelsHigh: max(1, Int(size.height)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        appearance.performAsCurrentDrawingAppearance {
            background.setFill()
            NSRect(x: 0, y: 0, width: size.width, height: size.height).fill()
            let origin = textView.textContainerOrigin
            let start = viewport.viewportRange?.location ?? content.documentRange.location
            var seen = 0
            manager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
                seen += 1
                let frame = fragment.layoutFragmentFrame
                let point = CGPoint(x: origin.x + frame.minX, y: origin.y + frame.minY)
                fragment.draw(at: point, in: context)
                return seen < 40 && frame.minY < size.height + 40
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return nonBackgroundPixels(
            in: rep,
            rect: NSRect(x: textView.textContainerInset.width, y: 0, width: max(1, size.width - textView.textContainerInset.width - 8), height: size.height),
            background: background
        )
    }

    private static func backgroundColor(_ appearance: NSAppearance) -> NSColor {
        var color = NSColor.textBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) ?? color
        }
        return color
    }

    private static func nonBackgroundPixels(in rep: NSBitmapImageRep, rect: NSRect, background: NSColor) -> Int {
        var count = 0
        let minX = max(0, Int(rect.minX.rounded(.up)))
        let maxX = min(rep.pixelsWide, Int(rect.maxX.rounded(.down)))
        let minY = max(0, Int(rect.minY.rounded(.up)))
        let maxY = min(rep.pixelsHigh, Int(rect.maxY.rounded(.down)))
        guard minX < maxX, minY < maxY else { return 0 }
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let distance = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if distance > 0.2 {
                    count += 1
                }
            }
        }
        return count
    }
}
#endif
