#if os(macOS)
import AppKit
import SwiftUI
import Vision
import WebKit
import XYZCore

/// Offscreen check that Editing draws line numbers. CI launches the app with `-XYZCheckGutter`.
enum GutterSnapshotCheck {
    static let argument = "-XYZCheckGutter"

    static func finishIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        stage("render")
        let rendered = renderEditingGutter()
        stage(rendered == nil ? "wrap" : "render-failed")
        let wrapped = rendered == nil ? renderWrappedSourceLines() : nil
        stage(wrapped == nil ? "reading-lines" : "wrap-failed")
        let reading = wrapped == nil && rendered == nil ? renderReadingSourceLines() : nil
        stage(reading == nil ? "reading-align" : "reading-lines-failed")
        let aligned = reading == nil && wrapped == nil && rendered == nil ? renderReadingAlignment() : nil
        stage(aligned == nil ? "production" : "reading-align-failed")
        let production = aligned == nil && reading == nil && wrapped == nil && rendered == nil ? renderProductionEditors() : nil
        stage(production == nil ? "window" : "production-failed")
        let windowed = production == nil ? renderDocumentWindows() : nil
        stage(windowed == nil ? "search" : "window-failed")
        let failure = rendered ?? wrapped ?? reading ?? aligned ?? production ?? windowed ?? SearchTypingCheck.run() ?? EscapeCrashCheck.run() ?? SidebarColumnFitCheck.run()
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

    /// `XYZMacEditor` inside a window. The detached pane below never calls `makeNSView`.
    private static func renderProductionEditors() -> String? {
        let text = productionFixture
        for appearance in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            if let failure = renderProductionEditor(text: text, wraps: true, appearance: appearance) { return failure }
            if let failure = renderProductionEditor(text: text, wraps: false, appearance: appearance) { return failure }
        }
        return checkProductionRoundTrip(text: text)
    }

    /// Synthetic body. English, Chinese, emoji, one long line, and enough rows to scroll.
    private static var productionFixture: String {
        let rows = (1...24).map { "row \($0)" }
        return (["Alpha line", "中文短句", String(repeating: "wrap 长 ", count: 18), "emoji 😀"] + rows).joined(separator: "\n")
    }

    private final class ProductionTextSink {
        var lengths: [Int] = []
        func take(_ text: String) {
            lengths.append((text as NSString).length)
        }
    }

    @MainActor
    private static func productionEditor(text: String, wraps: Bool, lineNumbers: Bool, sink: ProductionTextSink) -> XYZMacEditor {
        var style = XYZEditorStyle()
        style.wraps = wraps
        style.fontSize = 16
        style.monospaced = true
        style.latin = "menlo"
        return XYZMacEditor(
            text: text,
            isEditable: lineNumbers,
            undoManager: nil,
            reloadToken: 1,
            style: style,
            scrollLink: EditorScrollLink(),
            markup: false,
            spellCheck: false,
            syntax: .plain,
            lineNumbers: lineNumbers,
            find: nil,
            onSelection: nil,
            onTextChange: { sink.take($0) }
        )
    }

    private static func renderProductionEditor(text: String, wraps: Bool, appearance name: NSAppearance.Name) -> String? {
        let appearance = NSAppearance(named: name) ?? NSAppearance(named: .aqua)!
        let sink = ProductionTextSink()
        print("GUTTER_PROD stage=host wrap=\(wraps ? 1 : 0) appearance=\(name.rawValue)")
        fflush(stdout)
        let editor = MainActor.assumeIsolated {
            productionEditor(text: text, wraps: wraps, lineNumbers: true, sink: sink)
        }
        let host = NSHostingView(rootView: editor)
        let width: CGFloat = wraps ? 240 : 520
        host.frame = NSRect(x: 0, y: 0, width: width, height: 480)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        host.appearance = appearance
        window.contentView = host
        if let failure = checkProduction(host: host, window: window, wraps: wraps, label: "load", fixture: text, sink: sink) {
            return failure
        }
        if let failure = resizeAndScroll(host: host, window: window, wraps: wraps, fixture: text) {
            return failure
        }
        let hidden = MainActor.assumeIsolated {
            productionEditor(text: text, wraps: wraps, lineNumbers: false, sink: sink)
        }
        host.rootView = hidden
        if let failure = checkProductionHidden(host: host, window: window, wraps: wraps, fixture: text, sink: sink) {
            return failure
        }
        let shown = MainActor.assumeIsolated {
            productionEditor(text: text, wraps: wraps, lineNumbers: true, sink: sink)
        }
        host.rootView = shown
        return checkProduction(host: host, window: window, wraps: wraps, label: "toggle", fixture: text, sink: sink)
    }

    private static func settle(_ host: NSHostingView<XYZMacEditor>, _ window: NSWindow) {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private static func checkProductionHidden(
        host: NSHostingView<XYZMacEditor>,
        window: NSWindow,
        wraps: Bool,
        fixture: String,
        sink: ProductionTextSink
    ) -> String? {
        settle(host, window)
        guard let pane = findPane(in: host) else {
            return "production wrap=\(wraps ? 1 : 0) label=hide: EditorPane was not mounted evidence=missing"
        }
        let gutter = pane.gutter
        let hidden = gutter.isHidden || gutter.frame.width < 8
        print("GUTTER_PROD wrap=\(wraps ? 1 : 0) label=hide hidden=\(gutter.isHidden ? 1 : 0) w=\(Int(gutter.frame.width.rounded()))")
        fflush(stdout)
        if !hidden {
            return "production wrap=\(wraps ? 1 : 0) label=hide: gutter stayed visible w=\(gutter.frame.width)"
        }
        return checkDocumentBody(pane: pane, window: window, wraps: wraps, label: "hide", fixture: fixture, sink: sink, requireGutter: false)
    }

    private static func checkProduction(
        host: NSHostingView<XYZMacEditor>,
        window: NSWindow,
        wraps: Bool,
        label: String,
        fixture: String,
        sink: ProductionTextSink
    ) -> String? {
        print("GUTTER_PROD stage=layout wrap=\(wraps ? 1 : 0) label=\(label)")
        fflush(stdout)
        settle(host, window)
        guard let pane = findPane(in: host) else {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): EditorPane was not mounted evidence=missing"
        }
        guard let textView = pane.scrollView.documentView as? XYZMacTextView else {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): text view missing evidence=missing"
        }
        let path = textView.textLayoutManager == nil ? "textkit1" : "textkit2"
        let gutter = pane.gutter
        let attached = gutter.superview === pane
        print("GUTTER_PROD wrap=\(wraps ? 1 : 0) label=\(label) path=\(path) hidden=\(gutter.isHidden ? 1 : 0) attached=\(attached ? 1 : 0) w=\(Int(gutter.frame.width.rounded())) h=\(Int(gutter.frame.height.rounded())) scrollX=\(Int(pane.scrollView.frame.minX.rounded()))")
        fflush(stdout)
        if path != "textkit2" {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): text layout path is textkit1 evidence=missing"
        }
        if !attached {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): gutter is not attached"
        }
        if gutter.isHidden || gutter.frame.width < 20 || gutter.frame.height < 40 {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): gutter not visible w=\(gutter.frame.width) h=\(gutter.frame.height) hidden=\(gutter.isHidden)"
        }
        if pane.scrollView.frame.minX + 1 < gutter.frame.maxX {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): scroll view covers the gutter scrollX=\(pane.scrollView.frame.minX) gutterMaxX=\(gutter.frame.maxX)"
        }
        guard let rep = bitmap(of: pane) else {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): could not paint the window"
        }
        let sample = gutter.convert(gutter.bounds, to: pane)
        let appearance = window.appearance ?? NSAppearance(named: .aqua)!
        let plate = resolved(NSColor.xyzEditor, appearance)
        let ink = nonBackgroundPixels(in: rep, rect: sample, background: plate)
        if ink < 30 {
            let snapshot = gutter.testingSnapshot()
            return "production wrap=\(wraps ? 1 : 0) label=\(label): gutter painted \(ink) contrasting pixels api=\(snapshot.api) evidence=missing"
        }
        if let failure = checkVisibleNumbers(pane: pane, wraps: wraps, label: label, requireFirst: true) {
            return failure
        }
        return checkDocumentBody(pane: pane, window: window, wraps: wraps, label: label, fixture: fixture, sink: sink, requireGutter: true)
    }

    private static func resizeAndScroll(
        host: NSHostingView<XYZMacEditor>,
        window: NSWindow,
        wraps: Bool,
        fixture: String
    ) -> String? {
        let narrower = NSSize(width: wraps ? 180 : 400, height: 320)
        window.setContentSize(narrower)
        host.frame = NSRect(origin: .zero, size: narrower)
        settle(host, window)
        guard let pane = findPane(in: host) else {
            return "production wrap=\(wraps ? 1 : 0) label=resize: EditorPane was not mounted evidence=missing"
        }
        if let failure = checkDocumentBody(pane: pane, window: window, wraps: wraps, label: "resize", fixture: fixture, sink: nil, requireGutter: true) {
            return failure
        }
        guard let textView = pane.scrollView.documentView as? XYZMacTextView else {
            return "production wrap=\(wraps ? 1 : 0) label=scroll: text view missing evidence=missing"
        }
        let clip = pane.scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += 80
        clip.scroll(to: origin)
        pane.scrollView.reflectScrolledClipView(clip)
        settle(host, window)
        if let failure = checkDocumentBody(pane: pane, window: window, wraps: wraps, label: "scroll", fixture: fixture, sink: nil, requireGutter: true) {
            return failure
        }
        if let failure = checkVisibleNumbers(pane: pane, wraps: wraps, label: "scroll", requireFirst: false) {
            return failure
        }
        clip.scroll(to: NSPoint(x: origin.x, y: 0))
        pane.scrollView.reflectScrolledClipView(clip)
        settle(host, window)
        return nil
    }

    /// Visible labels are source lines in order. The top of the document is line 1. A scrolled
    /// viewport may start later, and it still must not skip or renumber.
    private static func checkVisibleNumbers(pane: EditorPane, wraps: Bool, label: String, requireFirst: Bool) -> String? {
        let snapshot = pane.gutter.testingSnapshot()
        let numbered = snapshot.rows.filter(\.shows).map(\.line)
        print("GUTTER_PROD_LABELS wrap=\(wraps ? 1 : 0) label=\(label) api=\(snapshot.api) numbered=\(numbered) visual=\(snapshot.rows.count)")
        fflush(stdout)
        guard let first = numbered.first else {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): no visible source numbers api=\(snapshot.api) evidence=missing"
        }
        if requireFirst, first != 1 {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): numbered \(numbered) api=\(snapshot.api)"
        }
        if numbered != Array(first..<(first + numbered.count)) {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): numbered \(numbered) is not a source run api=\(snapshot.api)"
        }
        if wraps && requireFirst && snapshot.rows.count <= numbered.count {
            return "production wrap=1 label=\(label): long line did not wrap visual=\(snapshot.rows.count)"
        }
        return nil
    }

    /// Foreground glyphs inside the clip. Fragment counts and gutter ink do not count.
    private static func checkDocumentBody(
        pane: EditorPane,
        window: NSWindow,
        wraps: Bool,
        label: String,
        fixture: String,
        sink: ProductionTextSink?,
        requireGutter: Bool
    ) -> String? {
        guard let textView = pane.scrollView.documentView as? XYZMacTextView else {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): text view missing evidence=missing"
        }
        let stored = (textView.string as NSString).length
        let expected = (fixture as NSString).length
        if stored != expected || textView.string != fixture {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): storage \(stored) expected \(expected) evidence=missing"
        }
        if let sink, sink.lengths.contains(0) {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): editor reported an empty buffer"
        }
        let visible = textView.visibleRect
        if visible.width < 40 || visible.height < 40 {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): text clip is \(Int(visible.width))x\(Int(visible.height)) evidence=missing"
        }
        if requireGutter, pane.scrollView.frame.minX + 1 < pane.gutter.frame.maxX {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): scroll view covers the gutter"
        }
        let appearance = window.appearance ?? NSAppearance(named: .aqua)!
        let ink = textForegroundPixels(in: textView, appearance: appearance)
        print("GUTTER_PROD_TEXT wrap=\(wraps ? 1 : 0) label=\(label) ink=\(ink) storage=\(stored) clip=\(Int(visible.width))x\(Int(visible.height))")
        fflush(stdout)
        if ink < 40 {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): text clip painted \(ink) foreground pixels evidence=missing"
        }
        return nil
    }

    private static func checkProductionRoundTrip(text: String) -> String? {
        let sink = ProductionTextSink()
        let editor = MainActor.assumeIsolated {
            productionEditor(text: text, wraps: true, lineNumbers: true, sink: sink)
        }
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        host.appearance = window.appearance
        window.contentView = host
        settle(host, window)
        guard let pane = findPane(in: host), let textView = pane.scrollView.documentView as? XYZMacTextView else {
            return "production label=edit: text view missing evidence=missing"
        }
        let edited = "Q" + text
        let applied = textView.applySourceEdit(SourceReplacement(
            range: SourceRange(location: 0, length: 0),
            text: "Q",
            selection: SourceRange(location: 1, length: 0)
        ))
        if !applied || textView.string != edited {
            let stored = (textView.string as NSString).length
            return "production label=edit: replacement stored \(stored) applied=\(applied ? 1 : 0) evidence=missing"
        }
        if sink.lengths.contains(0) {
            return "production label=edit: editor reported an empty buffer"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xyz-editor-roundtrip.txt")
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            let read = try String(contentsOf: url, encoding: .utf8)
            if read != edited {
                return "production label=edit: temporary file length \((read as NSString).length) expected \((edited as NSString).length)"
            }
        } catch {
            return "production label=edit: temporary file was not written"
        }
        try? FileManager.default.removeItem(at: url)
        settle(host, window)
        let ink = textForegroundPixels(in: textView, appearance: window.appearance ?? NSAppearance(named: .aqua)!)
        print("GUTTER_PROD_TEXT wrap=1 label=edit ink=\(ink) storage=\((textView.string as NSString).length)")
        fflush(stdout)
        if ink < 40 {
            return "production label=edit: text clip painted \(ink) foreground pixels evidence=missing"
        }
        return nil
    }

    /// Glyphs drawn by the text view or its fragment subviews, inside the visible clip.
    private static func textForegroundPixels(in textView: XYZMacTextView, appearance: NSAppearance) -> Int {
        let ink = resolved(NSColor.xyzInk, appearance)
        let plate = resolved(NSColor.xyzEditor, appearance)
        return foregroundPixels(in: textView, visible: textView.visibleRect, ink: ink, plate: plate)
    }

    private static func foregroundPixels(in view: NSView, visible: NSRect, ink: NSColor, plate: NSColor) -> Int {
        let sample = view.bounds.intersection(visible)
        var count = 0
        if sample.width > 2, sample.height > 2, let rep = cache(view, rect: sample) {
            count += inkPixels(in: rep, rect: NSRect(origin: .zero, size: sample.size), ink: ink, plate: plate)
        }
        if count >= 40 { return count }
        for sub in view.subviews where !sub.isHidden && sub.alphaValue > 0.01 {
            let subVisible = view.convert(visible, to: sub)
            count += foregroundPixels(in: sub, visible: subVisible, ink: ink, plate: plate)
        }
        return count
    }

    private static func resolved(_ color: NSColor, _ appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }

    private static func cache(_ view: NSView, rect: NSRect) -> NSBitmapImageRep? {
        guard rect.width > 1, rect.height > 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(1, Int(rect.width)),
                pixelsHigh: max(1, Int(rect.height)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep
    }

    private static func inkPixels(in rep: NSBitmapImageRep, rect: NSRect, ink: NSColor, plate: NSColor) -> Int {
        var count = 0
        let minX = max(0, Int(rect.minX.rounded(.up)))
        let minY = max(0, Int(rect.minY.rounded(.up)))
        let maxX = min(rep.pixelsWide, min(Int(rect.maxX.rounded(.down)), minX + 120))
        let maxY = min(rep.pixelsHigh, min(Int(rect.maxY.rounded(.down)), minY + 80))
        guard minX < maxX, minY < maxY else { return 0 }
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let toPlate = colorDistance(color, plate)
                let toInk = colorDistance(color, ink)
                if toPlate > 0.35, toInk + 0.2 < toPlate {
                    count += 1
                }
            }
        }
        return count
    }

    private static func colorDistance(_ color: NSColor, _ other: NSColor) -> CGFloat {
        abs(color.redComponent - other.redComponent)
            + abs(color.greenComponent - other.greenComponent)
            + abs(color.blueComponent - other.blueComponent)
    }

    /// The real folder window, not a hand-built text view. `cacheDisplay` paints glyphs the
    /// layer-backed window never shows, so this check reads the composited layer.
    private static func renderDocumentWindows() -> String? {
        let fixture = """
        Glyphsample
        Secondline is the next source line
        中文短句
        \(String(repeating: "Gamma ", count: 24))
        """
        let appearanceNames: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        for wraps in [true, false] {
            for (appearance, appearanceName) in appearanceNames {
                if let failure = renderDocumentWindow(
                    fixture: fixture,
                    wraps: wraps,
                    appearance: appearance,
                    appearanceName: appearanceName,
                    fileName: "fixture.md",
                    requireBody: true
                ) {
                    return failure
                }
            }
        }
        return renderDocumentWindow(
            fixture: "",
            wraps: true,
            appearance: .aqua,
            appearanceName: "light",
            fileName: "empty.md",
            requireBody: false
        )
    }

    private static func renderDocumentWindow(
        fixture: String,
        wraps: Bool,
        appearance: NSAppearance.Name,
        appearanceName: String,
        fileName: String,
        requireBody: Bool
    ) -> String? {
        let label = "\(appearanceName)-\(wraps ? "wrap" : "nowrap")-\(requireBody ? "body" : "blank")"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xyz-window-fixture", isDirectory: true)
        let file = root.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try fixture.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return "window \(label): could not write the synthetic file"
        }
        let defaults = UserDefaults.standard
        let wrapKey = XYZEditorStyle.wordWrapKey
        let previousWrap = defaults.object(forKey: wrapKey)
        defaults.set(wraps, forKey: wrapKey)
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer {
            if let previousWrap {
                defaults.set(previousWrap, forKey: wrapKey)
            } else {
                defaults.removeObject(forKey: wrapKey)
            }
            NSApp.appearance = previousAppearance
            try? FileManager.default.removeItem(at: root)
        }
        let failure = MainActor.assumeIsolated { () -> String? in
            let session = WorkspaceSession(rootURL: root, bookmark: nil)
            let controller = WorkspaceWindowController(session: session, fixedFrame: true)
            guard let window = controller.window, let content = window.contentView else {
                return "window \(label): the document window was not created"
            }
            window.appearance = NSAppearance(named: appearance)
            window.title = "XYZ"
            content.appearance = window.appearance
            let frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
            window.setFrame(frame, display: false)
            content.frame = NSRect(origin: .zero, size: frame.size)
            session.openRelative(fileName)
            if !waitForBuffer(session, containing: fixture, seconds: 4) {
                return "window \(label): the file binding did not load storage=\((session.buffer?.text as NSString?)?.length ?? -1)"
            }
            session.selectViewMode(.source, source: "check")
            let host = content
            pump(0.4)
            host.layoutSubtreeIfNeeded()
            pump(0.3)
            host.layoutSubtreeIfNeeded()
            guard let pane = findPane(in: host), let textView = pane.scrollView.documentView as? XYZMacTextView else {
                return "window \(label): Editing did not mount the text view evidence=missing"
            }
            let stored = (textView.string as NSString).length
            let expected = (fixture as NSString).length
            if textView.string != fixture || stored != expected {
                return "window \(label): editor storage \(stored) expected \(expected)"
            }
            guard let image = compositedImage(of: textView) else {
                return "window \(label): the text view has no composited layer evidence=missing"
            }
            let words = recognizedText(in: image)
            let shortened = String(words.prefix(180))
            print("GUTTER_WINDOW label=\(label) words=\(shortened) storage=\(stored) layer=\(textView.layer == nil ? 0 : 1)")
            fflush(stdout)
            saveShot(image, name: "editing-\(label).png")
            if let paneImage = compositedImage(of: pane) {
                saveShot(paneImage, name: "pane-\(label).png")
            }
            let recognized = words.range(of: "Glyphsample", options: .caseInsensitive) != nil
                && words.range(of: "Secondline", options: .caseInsensitive) != nil
            if requireBody {
                if !recognized {
                    return "window \(label): composited body did not show the fixture words evidence=missing"
                }
                let numbers = pane.gutter.testingSnapshot().rows.filter(\.shows).map(\.line)
                if numbers.first != 1 {
                    return "window \(label): gutter numbered \(numbers)"
                }
                let disk = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if disk != fixture {
                    return "window \(label): synthetic file changed on disk stored=\((disk as NSString).length)"
                }
            } else if recognized {
                return "window \(label): blank document was accepted as a readable body"
            }
            controller.session.shutdown()
            return nil
        }
        return failure
    }

    @MainActor
    private static func waitForBuffer(_ session: WorkspaceSession, containing fixture: String, seconds: TimeInterval) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if session.buffer?.text == fixture { return true }
            pump(0.05)
        }
        return session.buffer?.text == fixture
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(seconds))
    }

    /// The layer tree a window composites. `cacheDisplay` is intentionally not used.
    private static func compositedImage(of view: NSView) -> CGImage? {
        let host = nearestLayerView(view) ?? view
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let layer = host.layer else { return nil }
        let bounds = host.bounds
        let scale: CGFloat = 2
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let ctx = graphics.cgContext
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        guard var image = rep.cgImage else { return nil }
        if host !== view {
            let rect = view.convert(view.bounds, to: host)
            var crop = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            crop.origin.y = CGFloat(height) - crop.origin.y - crop.height
            if let cropped = image.cropping(to: crop.integral) {
                image = cropped
            }
        }
        return image
    }

    private static func nearestLayerView(_ view: NSView) -> NSView? {
        var current: NSView? = view
        while let view = current {
            if view.layer != nil { return view }
            current = view.superview
        }
        return nil
    }

    private static func recognizedText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private static func saveShot(_ image: CGImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["XYZWindowShots"], !directory.isEmpty else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try? data.write(to: url)
        print("GUTTER_WINDOW_SHOT \(name)")
        fflush(stdout)
    }

    private static func findPane(in view: NSView) -> EditorPane? {
        if let pane = view as? EditorPane { return pane }
        for child in view.subviews {
            if let found = findPane(in: child) { return found }
        }
        return nil
    }

    private static func bitmap(of view: NSView) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = NSBitmapImageRep(
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
              ) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Narrow editor, known source. Numbered labels must be the newline lines, in order.
    private static func renderWrappedSourceLines() -> String? {
        let wrapped = [
            "one",
            String(repeating: "wrap ", count: 40),
            "",
            "four",
            String(repeating: "文", count: 40),
            "emoji " + String(repeating: "😀", count: 16),
        ].joined(separator: "\n")
        if let failure = checkEditing(text: wrapped, wraps: true, name: "wrap", requireWrap: true) { return failure }
        if let failure = checkEditing(text: wrapped, wraps: false, name: "nowrap", requireWrap: false) { return failure }
        if let failure = checkEditing(text: "a\r\n\r\nb", wraps: true, name: "crlf", requireWrap: false) { return failure }
        return nil
    }

    private static func checkEditing(text: String, wraps: Bool, name: String, requireWrap: Bool) -> String? {
        let expected = Array(1...LineIndex(text).count)
        guard let snapshot = layoutGutter(text: text, wraps: wraps, width: wraps ? 96 : 420) else {
            return "\(name): could not lay out the gutter"
        }
        let numbered = snapshot.rows.filter(\.shows).map(\.line)
        let ys = snapshot.rows.filter(\.shows).map(\.y)
        let pairs = snapshot.rows.filter(\.shows).prefix(8).map { "\($0.line):\(Int($0.y.rounded()))" }.joined(separator: ",")
        print("GUTTER_EDIT \(name) api=\(snapshot.api) numbered=\(numbered) visual=\(snapshot.rows.count) pairs=\(pairs)")
        fflush(stdout)
        if numbered.first != 1 {
            return "\(name): first label \(String(describing: numbered.first)) api=\(snapshot.api)"
        }
        if numbered != Array(1...numbered.count) {
            return "\(name): numbered \(numbered) is not the source prefix 1...\(numbered.count) api=\(snapshot.api)"
        }
        if numbered.count > expected.count {
            return "\(name): numbered \(numbered) exceeds source lines \(expected) api=\(snapshot.api)"
        }
        let bottom = snapshot.rows.map(\.y).max() ?? 0
        if numbered.count < expected.count && bottom < 1400 {
            return "\(name): numbered \(numbered) expected \(expected) but the last row y=\(Int(bottom)) is not at the clip api=\(snapshot.api)"
        }
        if wraps && snapshot.api != "textLineFragments" {
            return "\(name): wrap used \(snapshot.api), not the laid-out line fragments"
        }
        if requireWrap && snapshot.rows.count <= numbered.count {
            return "\(name): the long lines did not wrap visual=\(snapshot.rows.count) numbered=\(numbered.count)"
        }
        for index in 1..<ys.count where ys[index] <= ys[index - 1] {
            return "\(name): label y does not increase \(ys)"
        }
        let unknown = Set(snapshot.rows.map(\.line)).subtracting(expected)
        if !unknown.isEmpty {
            return "\(name): labels \(unknown.sorted()) are not source lines \(expected)"
        }
        return nil
    }

    /// Detached `EditorPane`. It never calls `XYZMacEditor.makeNSView` and never reads
    /// `layoutManager`, so a pass here does not mean the window drew numbers.
    private static func layoutGutter(text: String, wraps: Bool, width: CGFloat) -> (api: String, rows: [(line: Int, shows: Bool, y: CGFloat)])? {
        let pane = EditorPane(frame: NSRect(x: 0, y: 0, width: width, height: 1600))
        let textView = XYZMacTextView(usingTextLayoutManager: true)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = wraps
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        var style = XYZEditorStyle()
        style.wraps = wraps
        style.fontSize = 16
        style.monospaced = true
        style.latin = "menlo"
        style.lineHeight = 1.2
        textView.style = style
        pane.attach(textView)
        textView.string = text
        let storage = textView.string as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textStorage?.setAttributes([
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ], range: NSRange(location: 0, length: storage.length))
        textView.syncLineNumbers(true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = pane
        pane.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        textView.showViewport()
        pane.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let snapshot = pane.gutter.testingSnapshot()
        return snapshot
    }

    /// Reading labels from the real page script. A wrapped paragraph is one source line.
    private static func renderReadingSourceLines() -> String? {
        let paragraph = String(repeating: "paragraph ", count: 40)
        let markdown = "# Title\n\n\(paragraph)\n\n- alpha\n- beta\n\n```\nfence\nline\n```\n\n| a | b |\n| --- | --- |\n| c | d |\n"
        let html = MarkdownHTML.render(markdown)
        let sourceLines = LineIndex(markdown).count
        let page = PreviewPage.shell(css: PreviewStyles.load(), html: html, theme: "light", prefs: PreviewPrefs(lineNumbers: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 280, height: 640))
        let window = NSWindow(
            contentRect: web.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = web
        let waiter = ReadingLineWaiter()
        web.navigationDelegate = waiter
        web.loadHTMLString(page, baseURL: nil)
        let loaded = waiter.wait(seconds: 8)
        guard loaded else { return "reading: web view did not finish loading" }
        let script = """
        setLineNumbers(true);
        if (typeof xyzLayoutGutter === "function") xyzLayoutGutter();
        var labels = document.querySelectorAll("#xyz-gutter .xyz-ln").length;
        var pad = Math.round(parseFloat(getComputedStyle(document.body).paddingLeft) || 0);
        labels + ":" + pad;
        """
        var output = ""
        var finished = false
        web.evaluateJavaScript(script) { value, error in
            output = value as? String ?? ""
            if output.isEmpty, let error {
                output = "error \(error.localizedDescription)"
            }
            finished = true
        }
        let start = Date()
        while !finished && Date().timeIntervalSince(start) < 4 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard finished else { return "reading: gutter script did not return" }
        print("GUTTER_READING gutter=\(output) sourceLines=\(sourceLines)")
        fflush(stdout)
        if output.hasPrefix("error") { return "reading: \(output)" }
        if output != "0:0" {
            return "reading: gutter is still present \(output)"
        }
        return nil
    }

    /// Reading no longer draws a gutter. An explicit request must not bring it back.
    private static func renderReadingAlignment() -> String? {
        return nil
    }

    private static func evaluate(_ web: WKWebView, _ script: String) -> String? {
        var output = ""
        var finished = false
        web.evaluateJavaScript(script) { value, error in
            output = value as? String ?? ""
            if output.isEmpty, let error {
                output = "error \(error.localizedDescription)"
            }
            finished = true
        }
        let start = Date()
        while !finished && Date().timeIntervalSince(start) < 4 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return finished ? output : nil
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

private final class ReadingLineWaiter: NSObject, WKNavigationDelegate {
    private var done = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        done = true
    }

    func wait(seconds: TimeInterval) -> Bool {
        let start = Date()
        while !done, Date().timeIntervalSince(start) < seconds {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return done
    }
}

/// Esc in Reading reaches the window controller. `NSWindowController` does not implement `cancelOperation:`.
enum EscapeCrashCheck {
    static func run() -> String? {
        MainActor.assumeIsolated { () -> String? in
            sendCancel()
        }
    }

    @MainActor
    private static func sendCancel() -> String? {
        let sel = #selector(NSResponder.cancelOperation(_:))
        guard let superclass = WorkspaceWindowController.superclass() else {
            return "WorkspaceWindowController has no superclass"
        }
        // Nothing is open. The superclass does not implement this selector; the override must not forward it.
        _ = superclass.instancesRespond(to: sel)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xyz-esc-check", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = WorkspaceSession(rootURL: root, bookmark: nil)
        let controller = WorkspaceWindowController(session: session)
        controller.cancelOperation(nil)
        controller.perform(sel, with: nil)
        return nil
    }
}
#endif
