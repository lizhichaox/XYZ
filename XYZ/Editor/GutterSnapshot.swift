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
        if ProcessInfo.processInfo.arguments.contains("-XYZPerfProbe") {
            MainActor.assumeIsolated {
                runPerfProbe()
            }
            exit(0)
        }
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
        // The folder window is the content gate. A line-number failure must not hide its picture.
        let windowed = renderDocumentWindows()
        stage(windowed == nil ? "search" : "window-failed")
        if let production {
            print("GUTTER_PROD_NOTE \(production)")
            fflush(stdout)
        }
        let sidebar = SidebarColumnFitCheck.run()
        let gestures = runAcceptanceGestures()
        if let gestures {
            print("GUTTER_GESTURE_FAIL \(gestures)")
        } else {
            print("GUTTER_GESTURE pass")
        }
        fflush(stdout)
        // Body result. The acceptance lines are a separate required check and are not dropped.
        let parts = [rendered, wrapped, reading, aligned, production, windowed, SearchTypingCheck.run(), EscapeCrashCheck.run(), sidebar].compactMap { $0 }
        let failure = parts.isEmpty ? nil : parts.joined(separator: " | ")
        stage("done")
        if let failure {
            print("GUTTER_MISSING \(failure)")
        } else {
            print("GUTTER_OK")
        }
        fflush(stdout)
        exit(failure == nil ? 0 : 1)
    }

    /// `-XYZPerfProbe`: repeatable numbers for the optimization work. Not part of the
    /// acceptance gate; it builds one large note in a window and prints PERF lines.
    @MainActor
    private static func runPerfProbe() {
        func now() -> Double { CFAbsoluteTimeGetCurrent() }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2] * 1000
        }

        let lines = (1...2000).map { i -> String in
            switch i % 7 {
            case 0: return "## 标题 Heading \(i)"
            case 1: return "- 中文 list item \(i) with [link](note\(i).md) and `inline_code_\(i)`"
            case 2: return "这是第 \(i) 行混排正文 mixed Chinese and English text for wrapping and measuring."
            default: return "line \(i) plain text with some words and 中文 characters to wrap the row nicely."
            }
        }
        let fixture = lines.joined(separator: "\n")
        var style = XYZEditorStyle()
        style.wraps = true
        style.fontSize = 16
        let editor = XYZMacEditor(
            text: fixture,
            isEditable: true,
            undoManager: nil,
            reloadToken: 1,
            style: style,
            scrollLink: EditorScrollLink(),
            markup: true,
            syntax: .markdown,
            lineNumbers: true,
            find: nil,
            onSelection: nil,
            onTextChange: { _ in }
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        var pane: EditorPane?
        let start = now()
        while now() - start < 8 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let found = findPane(in: host),
               let textView = found.scrollView.documentView as? XYZMacTextView,
               (textView.string as NSString).length > 50_000,
               found.frame.width > 100, found.frame.height > 100 {
                pane = found
                break
            }
            pump(0.05)
        }
        guard let pane,
              let textView = pane.scrollView.documentView as? XYZMacTextView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else {
            print("PERF setup=failed")
            fflush(stdout)
            return
        }
        let length = (textView.string as NSString).length
        print("PERF fixture lines=\(lines.count) chars=\(length) load_ms=\((now() - start) * 1000)")
        fflush(stdout)

        let gutter = pane.gutter
        let scrollView = pane.scrollView
        let clip = scrollView.contentView
        let maxOffset = max(0, textView.frame.height - clip.bounds.height)
        func scroll(to fraction: Double) {
            clip.bounds.origin.y = min(maxOffset, max(0, maxOffset * fraction))
            scrollView.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            pump(0.02)
        }
        scroll(to: 0.5)
        var snapshots: [Double] = []
        var draws: [Double] = []
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            scroll(to: fraction)
            for _ in 0..<4 {
                let begin = now()
                _ = gutter.testingSnapshot()
                snapshots.append(now() - begin)
            }
            for _ in 0..<4 {
                let begin = now()
                gutter.display()
                draws.append(now() - begin)
            }
        }
        print("PERF guttersnap_ms=\(String(format: "%.2f", median(snapshots))) gutterdraw_ms=\(String(format: "%.2f", median(draws)))")
        fflush(stdout)

        var scrollTimes: [Double] = []
        for step in 0..<40 {
            let begin = now()
            scroll(to: Double(step % 20) / 20)
            window.displayIfNeeded()
            scrollTimes.append(now() - begin)
        }
        print("PERF scroll_ms=\(String(format: "%.2f", median(scrollTimes)))")
        fflush(stdout)

        let fullBegin = now()
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
        print("PERF full_layout_ms=\((now() - fullBegin) * 1000)")
        fflush(stdout)

        scroll(to: 0.5)
        textView.setSelectedRange(NSRange(location: min(length - 2, length / 2), length: 0))
        var inserts: [Double] = []
        var displays: [Double] = []
        var applies: [Double] = []
        for _ in 0..<12 {
            let insertBegin = now()
            textView.insertText("字", replacementRange: textView.selectedRange())
            inserts.append(now() - insertBegin)
            let displayBegin = now()
            window.displayIfNeeded()
            displays.append(now() - displayBegin)
            let applyBegin = now()
            EditorTypography.apply(
                to: textView,
                style: style,
                markup: true,
                language: .markdown,
                edited: textView.selectedRange()
            )
            applies.append(now() - applyBegin)
        }
        // Cost of the strings the workspace callbacks touch on every keystroke.
        let copyBegin = now()
        let copied = textView.string
        print("PERF text_copy_ms=\((now() - copyBegin) * 1000) chars=\((copied as NSString).length)")
        let statsBegin = now()
        _ = TextStatistics.count(copied)
        print("PERF word_count_ms=\((now() - statsBegin) * 1000)")
        let outlineBegin = now()
        _ = FileOutline.entries(in: copied, language: .markdown)
        print("PERF outline_ms=\((now() - outlineBegin) * 1000)")
        let findBegin = now()
        let query = FindQuery(pattern: "line")
        let matches = TextFind.matches(in: copied, query: query)
        print("PERF find_ms=\((now() - findBegin) * 1000) matches=\(matches.count)")
        let replaceBegin = now()
        _ = TextFind.replaceAll(in: copied, query: query, with: "row")
        print("PERF find_replace_ms=\((now() - replaceBegin) * 1000)")
        fflush(stdout)

        // Reading: rendering cost and the per-scroll JS scan over data-line blocks.
        let renderBegin = now()
        let html = MarkdownHTML.render(fixture)
        print("PERF reading_render_ms=\((now() - renderBegin) * 1000) html_kb=\(html.utf8.count / 1024)")
        fflush(stdout)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(BundledFontSchemeHandler(), forURLScheme: AppFonts.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        web.loadHTMLString(
            PreviewPage.shell(css: PreviewStyles.load(), html: html, theme: "light", prefs: PreviewPrefs()),
            baseURL: nil
        )
        let loadStart = now()
        while now() - loadStart < 8, web.isLoading || web.url == nil {
            pump(0.05)
        }
        web.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        web.layoutSubtreeIfNeeded()
        pump(0.3)
        var readingResult: String?
        web.callAsyncJavaScript("""
            const max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
            const blocks = document.querySelectorAll('[data-line]').length;
            let t = performance.now();
            for (let i = 0; i < 120; i++) {
              window.scrollTo(0, (max * (i % 60)) / 60);
              xyzReport();
              xyzMarkCurrentLine();
            }
            const report = performance.now() - t;
            t = performance.now();
            for (let i = 0; i < 120; i++) {
              window.scrollTo(0, (max * (i % 12)) / 12);
              xyzTop();
            }
            const top = performance.now() - t;
            const html = document.getElementById('content').innerHTML;
            t = performance.now();
            for (let i = 0; i < 3; i++) { setContent(html); }
            const setContentMs = performance.now() - t;
            return 'scroll_report_ms=' + report.toFixed(1) + ' top_only_ms=' + top.toFixed(1)
              + ' setcontent_ms=' + setContentMs.toFixed(1) + ' blocks=' + blocks + ' max=' + Math.round(max);
            """, arguments: [:], in: nil, in: .page) { completion in
                switch completion {
                case .success(let value): readingResult = value as? String ?? "invalid"
                case .failure(let error): readingResult = error.localizedDescription
                }
            }
        let readingStart = now()
        while readingResult == nil, now() - readingStart < 10 {
            pump(0.05)
        }
        print("PERF reading \(readingResult ?? "timeout")")
        fflush(stdout)
        // Full restyle cost and the stall after a typing pause (the 280 ms laterRestyle).
        let fullApplyBegin = now()
        EditorTypography.apply(to: textView, style: style, markup: true, language: .markdown, edited: nil)
        print("PERF apply_full_ms=\((now() - fullApplyBegin) * 1000)")
        fflush(stdout)
        textView.setSelectedRange(NSRange(location: min(length - 2, length / 2), length: 0))
        textView.insertText("字", replacementRange: textView.selectedRange())
        let pauseBegin = now()
        pump(0.45)
        print("PERF typing_pause_ms=\((now() - pauseBegin) * 1000)")
        fflush(stdout)
        print("PERF insert_ms=\(String(format: "%.2f", median(inserts))) display_ms=\(String(format: "%.2f", median(displays))) apply_ms=\(String(format: "%.2f", median(applies)))")
        fflush(stdout)
        window.close()
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
        return XYZMacEditor(
            text: text,
            isEditable: lineNumbers,
            undoManager: nil,
            reloadToken: 1,
            style: style,
            scrollLink: EditorScrollLink(),
            markup: false,
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
        return checkProduction(host: host, window: window, wraps: wraps, label: "restored", fixture: text, sink: sink)
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
        if textView.string.isEmpty {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): text view is empty evidence=missing"
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

    /// Set when a titled window's web view is readable in the same capture as AppKit text.
    private static var webCaptureSeesText = false

    /// A titled window with ordinary AppKit text. If this picture has no words, the
    /// capture is blind and a blank editor shot is not evidence.
    private static func verifyCaptureControl() -> String? {
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 520, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Capture"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        let label = NSTextField(labelWithString: "Captureprobe")
        label.frame = NSRect(x: 24, y: 180, width: 460, height: 24)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 40, width: 460, height: 120))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 120))
        text.string = "Nativebody"
        text.isEditable = true
        text.isSelectable = true
        text.drawsBackground = true
        scroll.documentView = text
        content.addSubview(label)
        content.addSubview(scroll)
        window.contentView = content
        window.orderFrontRegardless()
        window.displayIfNeeded()
        pump(0.4)
        let image = shownImage(of: window, content: content)
        window.close()
        guard let image else {
            return "capture control: the titled window produced no picture evidence=missing"
        }
        saveShot(image, name: "window-capture-control.png")
        let words = recognizedText(in: image)
        print("GUTTER_WINDOW label=capture-control words=\(String(words.prefix(160)))")
        fflush(stdout)
        let recognized = words.range(of: "Captureprobe", options: .caseInsensitive) != nil
            && words.range(of: "Nativebody", options: .caseInsensitive) != nil
        if !recognized {
            return "capture control: native text was not in the window picture evidence=missing words=\(String(words.prefix(80)))"
        }
        return nil
    }

    /// Same capture as the text control, with only a web view. Tells a blank Reading
    /// picture from a capture that never includes web content.
    private static func verifyWebCaptureControl() {
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 520, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Web"
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        let waiter = ReadingLineWaiter()
        web.navigationDelegate = waiter
        window.contentView = web
        window.orderFrontRegardless()
        web.loadHTMLString("<html><body style=\"font: 28px -apple-system, sans-serif; color: black; background: white\">Webprobe</body></html>", baseURL: nil)
        let loaded = waiter.wait(seconds: 4)
        pump(0.4)
        window.displayIfNeeded()
        let image = shownImage(of: window, content: web)
        let words = image.map { recognizedText(in: $0) } ?? ""
        if let image {
            saveShot(image, name: "window-web-control.png")
        }
        print("GUTTER_WINDOW label=web-control words=\(String(words.prefix(120))) loaded=\(loaded ? 1 : 0)")
        fflush(stdout)
        webCaptureSeesText = words.range(of: "Webprobe", options: .caseInsensitive) != nil
        window.close()
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
        var failures: [String] = []
        if let failure = verifyCaptureControl() { failures.append(failure) }
        verifyWebCaptureControl()
        let appearanceNames: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        for wraps in [true, false] {
            for (appearance, appearanceName) in appearanceNames {
                if let failure = renderDocumentWindow(
                    fixture: fixture,
                    wraps: wraps,
                    appearance: appearance,
                    appearanceName: appearanceName,
                    fileName: "fixture.md",
                    requireBody: true,
                    checkReading: wraps && appearance == .aqua
                ) {
                    failures.append(failure)
                }
            }
        }
        if let failure = renderLongScroll() { failures.append(failure) }
        if let failure = renderSwitchedFile() { failures.append(failure) }
        if let failure = renderDocumentWindow(
            fixture: "",
            wraps: true,
            appearance: .aqua,
            appearanceName: "light",
            fileName: "empty.md",
            requireBody: false
        ) {
            failures.append(failure)
        }
        return failures.isEmpty ? nil : failures.joined(separator: " | ")
    }

    private static func renderDocumentWindow(
        fixture: String,
        wraps: Bool,
        appearance: NSAppearance.Name,
        appearanceName: String,
        fileName: String,
        requireBody: Bool,
        checkReading: Bool = false
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
            let controller = WorkspaceWindowController(session: session)
            guard let window = controller.window, let host = window.contentView else {
                return "window \(label): the document window was not created"
            }
            window.appearance = NSAppearance(named: appearance)
            window.title = "XYZ"
            host.appearance = window.appearance
            window.orderFrontRegardless()
            session.openRelative(fileName)
            if !waitForBuffer(session, containing: fixture, seconds: 4) {
                return "window \(label): the file binding did not load storage=\((session.buffer?.text as NSString?)?.length ?? -1)"
            }
            var readingFailure: String?
            if checkReading {
                let page = waitForReadingText(in: host, needle: "Glyphsample", seconds: 4)
                if let web = findWebView(in: host) {
                    print("GUTTER_WINDOW web=\(Int(web.frame.width))x\(Int(web.frame.height)) hidden=\(web.isHidden ? 1 : 0) alpha=\(web.alphaValue) superview=\(web.superview == nil ? 0 : 1)")
                    fflush(stdout)
                    if let snapshot = webSnapshot(web) {
                        saveShot(snapshot, name: "reading-webview-snapshot-\(label).png")
                        let painted = recognizedText(in: snapshot, languages: ["zh-Hans", "en-US"])
                        let showsNote = contains(painted, "Glyphsample") && contains(painted, "Secondline")
                            && (contains(painted, "中文") || contains(painted, "短句"))
                        print("GUTTER_CHECK reading-snapshot=\(showsNote ? "pass" : "fail") words=\(String(painted.prefix(120)))")
                        fflush(stdout)
                        if !showsNote {
                            readingFailure = "window \(label): Reading web snapshot did not show the rendered note words=\(String(painted.prefix(60)))"
                        }
                    } else {
                        print("GUTTER_CHECK reading-snapshot=missing")
                        fflush(stdout)
                        readingFailure = "window \(label): Reading web snapshot was not produced"
                    }
                } else {
                    readingFailure = "window \(label): Reading web view is not in the folder window"
                }
                pump(0.4)
                window.displayIfNeeded()
                let columns = columnFrames(in: host)
                if let shot = shownImage(of: window, content: host) {
                    saveShot(shot, name: "window-\(label)-reading.png")
                    let heard = recognizedText(in: shot)
                    print("GUTTER_WINDOW label=\(label)-reading words=\(String(heard.prefix(120))) page=\(String(page.prefix(80))) columns=\(columns)")
                    fflush(stdout)
                    let pageHasNote = page.contains("Glyphsample") && page.contains("Secondline") && page.contains("中文")
                    if webCaptureSeesText && !Self.showsFixture(heard) {
                        readingFailure = "window \(label): Reading did not show the open file evidence=missing words=\(String(heard.prefix(80))) page=\(String(page.prefix(40))) columns=\(columns)"
                    } else if !webCaptureSeesText && !pageHasNote {
                        readingFailure = "window \(label): Reading page did not load the file evidence=missing page=\(String(page.prefix(40)))"
                    } else if !webCaptureSeesText {
                        print("GUTTER_WINDOW label=\(label)-reading capture does not include web views; the page has the note")
                        fflush(stdout)
                    }
                } else {
                    readingFailure = "window \(label): Reading capture is missing evidence=missing columns=\(columns)"
                }
            }
            session.selectViewMode(.source, source: "check")
            pump(0.4)
            host.layoutSubtreeIfNeeded()
            pump(0.3)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let pane = findPane(in: host), let textView = pane.scrollView.documentView as? XYZMacTextView else {
                return "window \(label): Editing did not mount the text view evidence=missing"
            }
            let stored = (textView.string as NSString).length
            let expected = (fixture as NSString).length
            if textView.string != fixture || stored != expected {
                return "window \(label): editor storage \(stored) expected \(expected)"
            }
            textView.needsDisplay = true
            pane.needsDisplay = true
            textView.displayIfNeeded()
            pane.displayIfNeeded()
            window.displayIfNeeded()
            guard let image = compositedImage(of: textView) else {
                return "window \(label): the text view has no composited layer evidence=missing"
            }
            guard let windowImage = compositedImage(of: host) else {
                return "window \(label): the document window has no composited layer evidence=missing"
            }
            let bodyWords = recognizedText(in: image)
            let screen = shownImage(of: window, content: host)
            let words = recognizedText(in: screen ?? windowImage)
            let chain = layerChain(from: textView)
            let viewNames = textView.subviews.map { NSStringFromClass(type(of: $0)) }.joined(separator: ",")
            let box = textView.convert(textView.bounds, to: nil)
            let visible = textView.visibleRect
            let clipY = textView.enclosingScrollView?.contentView.bounds.origin.y ?? -1
            let rooted = layerReachesWindow(textView, window: window)
            print("GUTTER_WINDOW label=\(label) words=\(String(words.prefix(180))) body=\(String(bodyWords.prefix(120))) storage=\(stored) layer=\(textView.layer == nil ? 0 : 1) screen=\(screen == nil ? 0 : 1) chain=\(chain) views=\(viewNames) geom=\(Int(box.width))x\(Int(box.height))@\(Int(box.minX)),\(Int(box.minY)) visY=\(Int(visible.origin.y)) visH=\(Int(visible.height)) clipY=\(Int(clipY)) flip=\(textView.layer?.isGeometryFlipped == true ? 1 : 0) root=\(rooted ? 1 : 0)")
            fflush(stdout)
            saveShot(image, name: "editing-\(label).png")
            if let paneImage = compositedImage(of: pane) {
                saveShot(paneImage, name: "pane-\(label).png")
            }
            let shot = screen ?? windowImage
            saveShot(shot, name: "window-\(label).png")
            let editorCrop = screen.flatMap { cropWindowImage($0, view: textView, window: window) }
            if let editorCrop {
                saveShot(editorCrop, name: "window-\(label)-editor.png")
            }
            let cropWords = editorCrop.map {
                recognizedText(in: $0, languages: ["zh-Hans", "zh-Hant", "en-US"])
            } ?? ""
            let english = contains(words, "Glyphsample") && contains(words, "Secondline")
            let chinese = contains(words, "中文") || contains(cropWords, "中文") || contains(cropWords, "短句")
            let ink = editorCrop.map { inkCount($0) } ?? 0
            print("GUTTER_CHECK label=\(label) english=\(english ? 1 : 0) chinese=\(chinese ? 1 : 0) ink=\(ink) crop=\(String(cropWords.prefix(80)))")
            fflush(stdout)
            var issues: [String] = []
            if let readingFailure { issues.append(readingFailure) }
            if requireBody {
                if !english {
                    issues.append("window \(label): composited window did not show the fixture words evidence=missing body=\(String(bodyWords.prefix(80)))")
                } else if editorCrop != nil && ink < 40 {
                    issues.append("window \(label): the editor area of the window picture has no ink evidence=missing")
                } else if !chinese {
                    issues.append("window \(label): the Chinese line was not legible in the window picture crop=\(String(cropWords.prefix(40)))")
                }
                if let interaction = exerciseEditor(textView, window: window) {
                    print("GUTTER_CHECK label=\(label) typing=fail \(interaction)")
                    issues.append("window \(label): \(interaction)")
                } else {
                    print("GUTTER_CHECK label=\(label) typing=pass caret=pass undo=pass")
                }
                if let scroll = exerciseScroll(textView) {
                    print("GUTTER_CHECK label=\(label) scroll=fail \(scroll)")
                    issues.append("window \(label): \(scroll)")
                }
                if let screen, let gutterImage = cropWindowImage(screen, view: pane.gutter, window: window) {
                    let gutterInk = inkCount(gutterImage)
                    print("GUTTER_CHECK label=\(label) gutterInk=\(gutterInk)")
                    if gutterInk < 4 {
                        issues.append("window \(label): line numbers are not in the window picture evidence=missing")
                    }
                } else if requireBody {
                    issues.append("window \(label): line-number area was not in the window picture evidence=missing")
                }
                fflush(stdout)
                let disk = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if disk != fixture {
                    issues.append("window \(label): synthetic file changed on disk stored=\((disk as NSString).length)")
                }
            } else if english || chinese {
                issues.append("window \(label): blank document was accepted as a readable body")
                print("GUTTER_CHECK label=\(label) blank=fail")
            } else {
                print("GUTTER_CHECK label=\(label) blank=pass")
            }
            fflush(stdout)
            session.shutdown()
            return issues.isEmpty ? nil : issues.joined(separator: " | ")
        }
        return failure
    }

    /// Types into the real text view, checks the caret, then undoes. The note on screen is unchanged.
    private static func exerciseEditor(_ textView: XYZMacTextView, window: NSWindow) -> String? {
        let original = textView.string
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        if !textView.string.hasPrefix("Z") || String(textView.string.dropFirst()) != original {
            return "typing did not change the text view"
        }
        if textView.selectedRange().location != 1 {
            return "the caret did not follow the typed character"
        }
        textView.undoManager?.undo()
        if textView.string != original {
            textView.string = original
            return "undo did not restore the note"
        }
        return nil
    }

    /// Moves the real scroller when the note is taller than the clip, then returns to the top.
    private static func exerciseScroll(_ textView: XYZMacTextView) -> String? {
        guard let scroll = textView.enclosingScrollView else { return "scroll view missing" }
        let clip = scroll.contentView
        let before = clip.bounds.origin.y
        let room = textView.bounds.height - clip.bounds.height
        guard room > 24 else {
            print("GUTTER_CHECK scroll=fits")
            fflush(stdout)
            return nil
        }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: before + min(80, room)))
        scroll.reflectScrolledClipView(clip)
        NSAnimationContext.endGrouping()
        let after = clip.bounds.origin.y
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: before))
        scroll.reflectScrolledClipView(clip)
        NSAnimationContext.endGrouping()
        guard abs(after - before) > 1 else { return "scroll did not move the note" }
        print("GUTTER_CHECK scroll=pass")
        fflush(stdout)
        return nil
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

    /// A note taller than the clip. The short fixture fits, so it never moves the scroller.
    private static func renderLongScroll() -> String? {
        let lines = (1...80).map { "Longline \($0) stays one source line" }
        let fixture = lines.joined(separator: "\n")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xyz-window-long", isDirectory: true)
        let file = root.appendingPathComponent("long.md")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try fixture.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return "window long: could not write the synthetic file"
        }
        defer { try? FileManager.default.removeItem(at: root) }
        return MainActor.assumeIsolated { () -> String? in
            let session = WorkspaceSession(rootURL: root, bookmark: nil)
            defer { session.shutdown() }
            let controller = WorkspaceWindowController(session: session)
            guard let window = controller.window, let host = window.contentView else {
                return "window long: the document window was not created"
            }
            window.orderFrontRegardless()
            session.openRelative("long.md")
            if !waitForBuffer(session, containing: fixture, seconds: 4) {
                return "window long: the file did not load"
            }
            session.selectViewMode(.source, source: "check")
            guard let pane = waitForPane(in: host, window: window) else {
                return "window long: Editing did not mount the text view"
            }
            guard let textView = pane.scrollView.documentView as? XYZMacTextView else {
                return "window long: Editing did not mount the text view"
            }
            if let failure = exerciseScroll(textView) {
                return "window long: \(failure)"
            }
            var words = ""
            var saved = false
            for _ in 0..<6 {
                pump(0.25)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let image = shownImage(of: window, content: host) else { continue }
                if !saved {
                    saveShot(image, name: "window-long-scroll.png")
                    saved = true
                }
                let heard = recognizedText(in: image)
                let crop = cropWindowImage(image, view: textView, window: window)
                let cropWords = crop.map { recognizedText(in: $0, languages: ["en-US"]) } ?? ""
                words = heard
                if contains(heard, "Longline") || contains(cropWords, "Longline") {
                    saveShot(image, name: "window-long-scroll.png")
                    if textView.string != fixture {
                        return "window long: scrolling changed the note"
                    }
                    return nil
                }
            }
            return "window long: the scrolled note was not in the window picture words=\(String(words.prefix(60)))"
        }
    }

    /// One titled window, two files. The second file's words have to be the ones on screen.
    private static func renderSwitchedFile() -> String? {
        let first = "Glyphsample\nSecondline is the next source line\n中文短句\n"
        let second = "Plainleaf\nOtherfile is the plain note\n"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xyz-window-switch", isDirectory: true)
        let markdown = root.appendingPathComponent("fixture.md")
        let plain = root.appendingPathComponent("plain.txt")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try first.write(to: markdown, atomically: true, encoding: .utf8)
            try second.write(to: plain, atomically: true, encoding: .utf8)
        } catch {
            return "window switch: could not write the synthetic files"
        }
        defer { try? FileManager.default.removeItem(at: root) }
        return MainActor.assumeIsolated { () -> String? in
            let session = WorkspaceSession(rootURL: root, bookmark: nil)
            let controller = WorkspaceWindowController(session: session)
            guard let window = controller.window, let host = window.contentView else {
                return "window switch: the document window was not created"
            }
            window.orderFrontRegardless()
            session.openRelative("fixture.md")
            if !waitForBuffer(session, containing: first, seconds: 4) {
                return "window switch: the markdown file did not load"
            }
            session.selectViewMode(.source, source: "check")
            pump(0.5)
            window.displayIfNeeded()
            session.openRelative("plain.txt")
            if !waitForBuffer(session, containing: second, seconds: 4) {
                return "window switch: the plain file did not load storage=\((session.buffer?.text as NSString?)?.length ?? -1)"
            }
            let editorShowsPlain = waitUntil(2) {
                guard window.title.contains("plain.txt") else { return false }
                guard let pane = findPane(in: host),
                      pane.frame.width > 40,
                      let textView = pane.scrollView.documentView as? XYZMacTextView else { return false }
                return textView.string == second
            }
            guard editorShowsPlain else {
                return "window switch: the window did not show the plain note title=\(window.title)"
            }
            pump(0.35)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let image = shownImage(of: window, content: host) else {
                return "window switch: the document window has no composited layer evidence=missing"
            }
            let words = recognizedText(in: image)
            saveShot(image, name: "window-switch-plain.png")
            print("GUTTER_WINDOW label=switch words=\(String(words.prefix(160)))")
            fflush(stdout)
            let showsSecond = words.range(of: "Plainleaf", options: .caseInsensitive) != nil
                && words.range(of: "Otherfile", options: .caseInsensitive) != nil
            if !showsSecond {
                print("GUTTER_CHECK switch=fail")
                fflush(stdout)
                return "window switch: the plain file was not on screen evidence=missing words=\(String(words.prefix(80)))"
            }
            if session.buffer?.text != second {
                print("GUTTER_CHECK switch=fail buffer")
                fflush(stdout)
                return "window switch: the open buffer is not the plain file"
            }
            print("GUTTER_CHECK switch=pass")
            fflush(stdout)
            session.shutdown()
            return nil
        }
    }

    private static func columnFrames(in root: NSView) -> String {
        guard let split = findSplit(in: root) else { return "no-split" }
        let side = split.testingSidebarFrame()
        let main = split.testingDetailFrame()
        let outline = split.testingOutlineFrame()
        return "side=\(Int(side.width))x\(Int(side.height)) detail=\(Int(main.width))x\(Int(main.height)) outline=\(Int(outline.width)) split=\(Int(split.bounds.width))x\(Int(split.bounds.height))"
    }

    private static func findSplit(in view: NSView) -> XYZSplitView? {
        if let split = view as? XYZSplitView { return split }
        for child in view.subviews {
            if let found = findSplit(in: child) { return found }
        }
        return nil
    }

    /// The rendered note, from the page itself. Empty when the web view never got the file.
    private static func waitForReadingText(in root: NSView, needle: String, seconds: TimeInterval) -> String {
        let start = Date()
        var latest = ""
        while Date().timeIntervalSince(start) < seconds {
            let web = findWebView(in: root)
            if let web {
                var done = false
                web.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                    latest = value as? String ?? ""
                    done = true
                }
                let spin = Date()
                while !done && Date().timeIntervalSince(spin) < 0.4 {
                    pump(0.05)
                }
                if latest.contains(needle) { return latest }
            }
            pump(0.1)
        }
        return latest
    }

    /// WebKit's own picture of the page. Not a WindowServer screenshot.
    private static func webSnapshot(_ web: WKWebView) -> CGImage? {
        var image: CGImage?
        var done = false
        web.takeSnapshot(with: nil) { shot, _ in
            if let shot, let data = shot.tiffRepresentation, let rep = NSBitmapImageRep(data: data) {
                image = rep.cgImage
            }
            done = true
        }
        let start = Date()
        while !done, Date().timeIntervalSince(start) < 4 {
            pump(0.05)
        }
        return image
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews {
            if let found = findWebView(in: child) { return found }
        }
        return nil
    }

    /// The window server's picture of this window, or the composited content layer.
    private static func shownImage(of window: NSWindow, content: NSView) -> CGImage? {
        window.displayIfNeeded()
        let number = CGWindowID(window.windowNumber)
        if number != 0, let image = CGWindowListCreateImage(.null, .optionIncludingWindow, number, [.boundsIgnoreFraming, .bestResolution]), image.width > 20, image.height > 20 {
            return image
        }
        return compositedImage(of: content)
    }

    private static func layerReachesWindow(_ view: NSView, window: NSWindow) -> Bool {
        guard let root = window.contentView?.layer else { return false }
        var layer = view.layer
        var hops = 0
        while let current = layer, hops < 30 {
            if current === root { return true }
            layer = current.superlayer
            hops += 1
        }
        return false
    }

    private static func layerChain(from view: NSView) -> String {
        var names: [String] = []
        var layer = view.layer
        var hops = 0
        while let current = layer, hops < 8 {
            let name = String(describing: type(of: current))
            names.append(name)
            layer = current.superlayer
            hops += 1
        }
        return names.joined(separator: ">")
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

    private static func showsFixture(_ words: String) -> Bool {
        contains(words, "Glyphsample") && contains(words, "Secondline") && contains(words, "中文")
    }

    private static func contains(_ words: String, _ needle: String) -> Bool {
        words.range(of: needle, options: .caseInsensitive) != nil
    }

    /// The editor rectangle of a window-server image. Full-window recognition can miss
    /// one Chinese line that is painted there.
    private static func cropWindowImage(_ image: CGImage, view: NSView, window: NSWindow) -> CGImage? {
        let rect = view.convert(view.bounds, to: nil)
        let frame = window.frame
        guard frame.width > 1, frame.height > 1, rect.width > 1, rect.height > 1 else { return nil }
        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height
        var crop = CGRect(
            x: rect.minX * scaleX,
            y: (frame.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        crop = crop.intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard crop.width > 2, crop.height > 2 else { return nil }
        return image.cropping(to: crop.integral)
    }

    private static func inkCount(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var count = 0
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent < 0.82 || color.greenComponent < 0.82 || color.blueComponent < 0.82 {
                    count += 1
                }
                x += 3
            }
            y += 3
        }
        return count
    }

    private static func recognizedText(in image: CGImage, languages: [String] = ["en-US", "zh-Hans"]) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
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

    /// The editor is mounted only after the open file reaches the window. A picture taken earlier shows the empty state.
    private static func waitForPane(in host: NSView, window: NSWindow) -> EditorPane? {
        let start = Date()
        while Date().timeIntervalSince(start) < 4 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let pane = findPane(in: host),
               let textView = pane.scrollView.documentView as? XYZMacTextView,
               textView.string.contains("Longline"),
               pane.frame.width > 40, pane.frame.height > 40 {
                return pane
            }
            pump(0.1)
        }
        return findPane(in: host)
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
        style.lineHeight = 1.2
        textView.style = style
        pane.attach(textView)
        textView.string = text
        let storage = textView.string as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textStorage?.setAttributes([
            .font: font,
            .foregroundColor: NSColor.xyzInk,
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
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundledFontSchemeHandler(), forURLScheme: AppFonts.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 280, height: 640), configuration: config)
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
        textView.textColor = .xyzInk
        textView.textContainerInset = NSSize(width: 48, height: 8)
        textView.string = "alpha\nbeta\ngamma\ndelta\nepsilon\n"
        let storage = textView.string as NSString
        textView.textStorage?.setAttributes([
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.xyzInk,
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

        if textView.textLayoutManager == nil, textView.string.isEmpty {
            return "\(label): text view has no text"
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

    /// Each original UI check has its own folder. A failed nested-file click does not skip the rest.

    /// Folding must collapse the laid-out height, leave the text alone, and open again.
    @MainActor
    private static func acceptCodeFolding() -> String? {
        let lines = (1...40).map { index in
            if index == 1 { return "func outer() {" }
            if index == 2 { return "    func inner() {" }
            if index == 3 { return "        work()" }
            if index == 4 { return "    }" }
            if index == 40 { return "}" }
            return "    step\(index)()"
        }
        let text = lines.joined(separator: "\n") + "\n"
        let textView = XYZMacTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 620, height: 800)
        textView.textContainer?.containerSize = NSSize(width: 620, height: 1_000_000)
        textView.textContainer?.widthTracksTextView = false
        textView.enableFolding()
        textView.sourceLanguage = .swift
        textView.string = text
        textView.refreshFolding(immediate: true)
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else {
            return "the text view has no TextKit 2 content manager"
        }
        func height() -> CGFloat {
            manager.ensureLayout(for: content.documentRange)
            manager.textViewportLayoutController.layoutViewport()
            return manager.usageBoundsForTextContainer.maxY
        }
        let before = height()
        guard textView.hasFoldableLines else { return "no foldable ranges were found" }
        textView.foldAll()
        let folded = height()
        guard folded < before * 0.5 else {
            return "folding did not collapse the layout (before \(Int(before)) folded \(Int(folded)))"
        }
        textView.unfoldAll()
        let reopened = height()
        guard abs(reopened - before) < 2 else {
            return "unfolding did not restore the layout (before \(Int(before)) reopened \(Int(reopened)))"
        }
        guard textView.string == text else { return "folding changed the text" }
        textView.toggleFold(atLine: 1)
        textView.unfoldFolds(intersecting: NSRange(location: 0, length: 0))
        guard textView.foldedHeaderLines.isEmpty == false || textView.hasFoldableLines else {
            return "the fold state disappeared"
        }
        return textKit1GutterClick()
    }

    /// Markdown headings fold in Editing, as they do in Obsidian's source mode and in
    /// VS Code's Markdown folding: a heading hides its section until the next heading of
    /// the same or a higher level.
    @MainActor
    private static func acceptMarkdownFolding() -> String? {
        let text = "# Alpha\nfirst body line\nsecond body line\n\n## Beta\nbeta body\n\n# Gamma\ngamma body\n"
        let textView = XYZMacTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 620, height: 800)
        textView.textContainer?.containerSize = NSSize(width: 620, height: 1_000_000)
        textView.textContainer?.widthTracksTextView = false
        textView.enableFolding()
        textView.sourceLanguage = .markdown
        textView.string = text
        textView.refreshFolding(immediate: true)
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager else {
            return "the Markdown view has no TextKit 2 content manager"
        }
        func height() -> CGFloat {
            manager.ensureLayout(for: content.documentRange)
            manager.textViewportLayoutController.layoutViewport()
            return manager.usageBoundsForTextContainer.maxY
        }
        guard textView.hasFoldableLines else { return "no Markdown heading folds were found" }
        guard let alpha = textView.foldableRanges.first(where: { $0.headerLine == 1 }) else {
            return "the first heading is not foldable"
        }
        guard alpha.lastLine == 6 else {
            return "the first heading fold ends at line \(alpha.lastLine), expected 6"
        }
        let before = height()
        textView.toggleFold(atLine: 1)
        let folded = height()
        guard folded < before else {
            return "folding a Markdown heading did not collapse the layout (before \(Int(before)) folded \(Int(folded)))"
        }
        guard textView.isLineHidden(3) else { return "the folded heading does not hide its body" }
        textView.unfoldAll()
        guard abs(height() - before) < 2 else {
            return "unfolding did not restore the layout (before \(Int(before)) reopened \(Int(height())))"
        }
        guard textView.string == text else { return "folding changed the text" }
        return nil
    }

    /// TextKit 1 view + gutter, laid out without a window: the chevron hit area must fold.
    @MainActor
    private static func textKit1GutterClick() -> String? {
        let text = (1...24).map { index in
            if index == 1 { return "func work() {" }
            if index == 2 { return "    one()" }
            if index == 3 { return "    two()" }
            if index == 24 { return "}" }
            return "    step\(index)()"
        }.joined(separator: "\n") + "\n"
        let textView = XYZMacTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 700))
        // Reading `layoutManager` installs TextKit 1, exactly like the hosted editor does.
        guard let layout = textView.layoutManager else { return "TextKit 1 layout manager missing" }
        layout.delegate = nil
        var style = XYZEditorStyle()
        style.fontSize = 15
        style.monospaced = true
        textView.style = style
        textView.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.textContainerInset = NSSize(width: 13, height: 8)
        textView.showsLineNumbers = true
        textView.enableFolding()
        textView.sourceLanguage = .swift
        textView.string = text
        textView.refreshFolding(immediate: true)
        let pane = EditorPane()
        pane.frame = NSRect(x: 0, y: 0, width: 640, height: 700)
        pane.attach(textView)
        pane.layoutSubtreeIfNeeded()
        textView.textContainer?.containerSize = NSSize(width: 620, height: 100_000)
        textView.textContainer?.widthTracksTextView = false
        textView.frame = NSRect(x: 0, y: 0, width: 620, height: 700)
        pane.layoutSubtreeIfNeeded()
        guard textView.hasFoldableLines else { return "TextKit 1 view found no foldable ranges" }
        guard let gutter = textView.lineNumberGutter else { return "TextKit 1 gutter is not installed" }
        gutter.frame = NSRect(x: 0, y: 0, width: 60, height: 700)
        gutter.layoutSubtreeIfNeeded()
        gutter.textView = textView
        layout.ensureLayout(for: textView.textContainer!)
        let before = layout.usedRect(for: textView.textContainer!).height
        guard before > 0 else { return "the TextKit 1 view never laid out (height 0)" }
        let pointInGutter = NSPoint(x: 7, y: 10)
        let pointInWindow = gutter.convert(pointInGutter, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { return "could not build a TextKit 1 gutter click" }
        // The click goes through the gutter's own hit test in the app; verify it answers.
        if let superview = gutter.superview {
            let windowPoint = gutter.convert(pointInGutter, to: superview)
            guard gutter.hitTest(windowPoint) === gutter else {
                return "the gutter chevron is not in the hit-test area"
            }
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        pump(0.1)
        gutter.mouseDown(with: event)
        pump(0.3)
        guard !textView.foldedHeaderLines.isEmpty else { return "a TextKit 1 gutter click did not fold" }
        guard textView.selectedRange().location == 0 else {
            return "a gutter click moved the caret to \(textView.selectedRange().location)"
        }
        layout.ensureLayout(for: textView.textContainer!)
        let after = layout.usedRect(for: textView.textContainer!).height
        guard after < before * 0.7 else {
            return "a TextKit 1 gutter click did not collapse (before \(Int(before)) after \(Int(after)))"
        }
        return nil
    }


    /// The same fold through the real folder window: the wiring that the synthetic text
    /// view case does not cover (content-storage delegate, gutter, editor refresh).
    @MainActor
    private static func acceptEditorFolding() -> String? {
        let code = (1...30).map { index in
            if index == 1 { return "func work() {" }
            if index == 2 { return "    let first = 1" }
            if index == 3 { return "    if first > 0 {" }
            if index == 4 { return "        print(first)" }
            if index == 5 { return "    }" }
            if index == 30 { return "}" }
            return "    step\(index)()"
        }.joined(separator: "\n") + "\n"
        guard let opened = acceptanceWindow(["code/sample.swift": code]) else {
            return "could not open the folding window"
        }
        defer { closeAcceptance(opened) }
        let (_, session, window, host) = opened
        session.openRelative("code/sample.swift")
        guard waitUntil(5, { session.buffer?.relativePath == "code/sample.swift" }) else {
            return "the code file did not open"
        }
        session.selectViewMode(.source, source: "check")
        pump(0.3)
        guard waitUntil(5, { findEditor(in: host) != nil }) else {
            return "the folder window has no editor"
        }
        pump(0.6)
        guard let pane = findPane(in: host),
              let textView = pane.scrollView.documentView as? XYZMacTextView,
              textView.string == code
        else {
            return "the editor is not showing the code file"
        }
        // The live editor still runs TextKit 1 (its layoutManager is read on purpose so
        // the hosted view paints); detached checks run TextKit 2. Both must fold.
        let usesTextKit2 = textView.textLayoutManager != nil
        let measure: () -> CGFloat
        if usesTextKit2 {
            guard let storage = textView.textLayoutManager?.textContentManager as? NSTextContentStorage,
                  storage.delegate != nil else {
                return "the TextKit 2 content storage delegate was never set"
            }
            guard let manager = textView.textLayoutManager, let content = manager.textContentManager else {
                return "the editor lost its content manager"
            }
            measure = {
                manager.ensureLayout(for: content.documentRange)
                manager.textViewportLayoutController.layoutViewport()
                return manager.usageBoundsForTextContainer.maxY
            }
        } else {
            guard let layout = textView.layoutManager, let container = textView.textContainer else {
                return "the real editor has neither layout system"
            }
            measure = {
                layout.ensureLayout(for: container)
                return layout.usedRect(for: container).height
            }
        }
        func height() -> CGFloat { measure() }
        guard textView.hasFoldableLines else {
            return "the real editor found no foldable ranges"
        }
        let before = height()
        textView.toggleFold(atLine: 1)
        pump(0.4)
        let folded = height()
        guard textView.foldedHeaderLines.contains(1) else { return "the fold state did not change" }
        guard folded < before * 0.7 else {
            return "folding in the real editor did not collapse (before \(Int(before)) folded \(Int(folded)))"
        }
        if let image = compositedImage(of: host) {
            saveShot(image, name: "editor-folding.png")
        }
        // The gutter is the way users fold: its chevron hit area must find the row and toggle.
        textView.unfoldAll()
        pump(0.2)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        guard let gutter = textView.lineNumberGutter else { return nil }
        gutter.layoutSubtreeIfNeeded()
        let pointInGutter = NSPoint(x: 7, y: 10)
        let pointInWindow = gutter.convert(pointInGutter, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { return "could not build a gutter click" }
        gutter.mouseDown(with: event)
        pump(0.4)
        let afterClick = height()
        guard !textView.foldedHeaderLines.isEmpty else {
            return "a gutter click did not fold (hit=\(gutter.hitTest(gutter.convert(pointInGutter, to: gutter.superview)) != nil))"
        }
        guard afterClick < before * 0.7 else {
            return "a gutter click did not collapse the layout (before \(Int(before)) after \(Int(afterClick)))"
        }
        return nil
    }

    @MainActor
    private static func findEditor(in root: NSView) -> XYZMacTextView? {
        guard let pane = findPane(in: root) else { return nil }
        return pane.scrollView.documentView as? XYZMacTextView
    }


    /// Reproduces the reported "cursor jumps" case: a nested JSON note is folded, then the
    /// caret goes to the end and a visible line is clicked. The caret must land on that line,
    /// and the caret row must stay inside the laid-out text.
    @MainActor
    private static func acceptFoldingCaret() -> String? {
        let json = "{\n  \"interval\": 60,\n  \"cloud_interval\": 600,\n  \"security_interval\": 900,\n  \"servers\": [\n    { \"host\": \"one\", \"port\": 22 },\n    { \"host\": \"two\", \"port\": 2222 },\n    { \"host\": \"three\", \"port\": 2222 },\n    { \"host\": \"four\", \"port\": 22 },\n    { \"host\": \"five\", \"port\": 22 },\n    { \"host\": \"six\", \"port\": 22 }\n  ],\n  \"tail\": true\n}\n"
        guard let opened = acceptanceWindow(["config.example.json": json]) else {
            return "could not open the folding window"
        }
        defer { closeAcceptance(opened) }
        let (_, session, window, host) = opened
        session.openRelative("config.example.json")
        guard waitUntil(5, { session.buffer?.relativePath == "config.example.json" }) else {
            return "the JSON note did not open"
        }
        session.selectViewMode(.source, source: "check")
        guard waitUntil(5, { findEditor(in: host) != nil }) else { return "no editor" }
        pump(0.6)
        guard let pane = findPane(in: host), let textView = pane.scrollView.documentView as? XYZMacTextView else {
            return "the editor is missing"
        }
        guard textView.hasFoldableLines, let fold = textView.foldableRanges.first(where: { $0.lineCount >= 6 }) else {
            return "the JSON note has no foldable block"
        }
        // Folding must not move the caret: the report was a caret that jumped away.
        let originalCaret = NSRange(location: (textView.string as NSString).range(of: "interval").location, length: 0)
        textView.setSelectedRange(originalCaret)
        pump(0.2)
        textView.toggleFold(atLine: fold.headerLine)
        pump(0.4)
        guard NSEqualRanges(textView.selectedRange(), originalCaret) else {
            return "folding moved the caret from \(originalCaret) to \(textView.selectedRange())"
        }
        guard textView.foldedHeaderLines.contains(fold.headerLine) else { return "the fold did not open" }
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            return "no TextKit 1 layout"
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // The outer JSON fold leaves one row. It can legitimately be <20pt with
        // smaller saved font/spacing preferences; validate against its actual metrics.
        let base = EditorTypography.baseFont(textView.style)
        let minimumRow = EditorTypography.paragraphStyle(textView.style, font: base).minimumLineHeight
        guard used.height >= minimumRow - 0.5 else {
            return "the folded document is shorter than one row: \(used.height) < \(minimumRow)"
        }
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
        pump(0.3)
        let rows = textView.visibleTextRows(in: textView.bounds)
        let caret = textView.selectedRange().location
        guard let caretRow = rows.first(where: {
            NSLocationInRange(caret, $0.charRange) || caret == NSMaxRange($0.charRange)
        }) else {
            return "the caret at the end matches no row (rows=\(rows.count))"
        }
        let contentBottom = textView.textContainerOrigin.y + used.maxY
        guard caretRow.rect.minY < contentBottom + 2 else {
            return "the caret row is below the laid-out text: rowY=\(Int(caretRow.rect.minY)) bottom=\(Int(contentBottom))"
        }
        if let image = compositedImage(of: host) {
            saveShot(image, name: "editor-folding-caret.png")
        }
        guard let target = rows.last(where: { $0.line > fold.lastLine }) else {
            return "no visible line after the folded block"
        }
        let windowPoint = textView.convert(NSPoint(x: target.rect.minX + 8, y: target.rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { return "could not build a click" }
        textView.mouseDown(with: event)
        pump(0.3)
        let clickedLine = EditorScrollAnchor.lineNumber(at: textView.selectedRange().location, in: textView.string)
        guard clickedLine == target.line else {
            return "clicking line \(target.line) placed the caret on line \(clickedLine)"
        }
        return nil
    }


    /// The caret band after every kind of placement, with the JSON note from the report.
    @MainActor
    private static func acceptCaretBand() -> String? {
        let json = "{\n  \"interval\": 60,\n  \"cloud_interval\": 600,\n  \"security_interval\": 900,\n  \"servers\": [\n    { \"id\": \"example-server\", \"name\": \"Example server\" },\n    { \"id\": \"other\", \"name\": \"Other server\" }\n  ],\n  \"tail\": true\n}\n"
        guard let opened = acceptanceWindow(["config.example.json": json]) else {
            return "could not open the window"
        }
        defer { closeAcceptance(opened) }
        let (_, session, window, host) = opened
        session.openRelative("config.example.json")
        guard waitUntil(5, { session.buffer?.relativePath == "config.example.json" })
        else { return "the JSON note did not open" }
        session.selectViewMode(.source, source: "check")
        guard waitUntil(5, { findEditor(in: host) != nil }) else { return "no editor" }
        pump(0.6)
        guard let pane = findPane(in: host),
              let textView = pane.scrollView.documentView as? XYZMacTextView,
              let layout = textView.layoutManager,
              let container = textView.textContainer
        else { return "the editor is missing" }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let contentBottom = textView.textContainerOrigin.y + used.maxY
        guard contentBottom > 40 else { return "the note has no height" }
        func check(_ label: String, _ caret: Int) -> String? {
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            pump(0.15)
            let rows = textView.visibleTextRows(in: textView.bounds)
            guard let band = textView.currentLineBandRect(in: textView.bounds) else {
                return "\(label): no caret band for caret \(caret) rows=\(rows.count)"
            }
            guard band.height <= 44 else {
                return "\(label): caret band is \(Int(band.height))pt tall at y=\(Int(band.minY))"
            }
            guard band.minY >= -1, band.minY < contentBottom + 1 else {
                return "\(label): caret band y=\(Int(band.minY)) outside text bottom=\(Int(contentBottom))"
            }
            let caretLine = EditorScrollAnchor.lineNumber(at: caret, in: textView.string)
            print("CARET_BAND label=\(label) caret=\(caret) line=\(caretLine) band=\(NSStringFromRect(band)) rows=\(rows.map { Int($0.rect.minY) }) lines=\(rows.map(\.line))")
            fflush(stdout)
            if let row = rows.first(where: { $0.line == caretLine }) {
                guard abs(row.rect.minY - band.minY) < 3 else {
                    return "\(label): band y=\(Int(band.minY)) but line row y=\(Int(row.rect.minY))"
                }
            }
            return nil
        }
        let ns = textView.string as NSString
        var failures: [String] = []
        for probe in [
            ("doc-start", 0),
            ("line-3", ns.range(of: "\"cloud_interval\"").location),
            ("line-5", ns.range(of: "\"servers\"").location),
            ("doc-end", ns.length),
            ("just-before-end", max(0, ns.length - 1)),
        ] {
            if let failure = check(probe.0, probe.1) {
                failures.append(failure)
                break
            }
        }
        if let image = shownImage(of: window, content: host) {
            saveShot(image, name: "caret-band-unfolded.png")
        }
        // Fold, repeat the end-of-document probe, unfold, repeat again: the report came
        // after opening and closing folds, where stale attributes would show up.
        if let fold = textView.foldableRanges.first(where: { $0.lineCount >= 3 }) {
            textView.toggleFold(atLine: fold.headerLine)
            pump(0.4)
            if let failure = check("folded-doc-end", ns.length) {
                failures.append(failure)
            }
            textView.unfoldAll()
            pump(0.4)
            if let failure = check("unfolded-doc-end", ns.length) {
                failures.append(failure)
            }
            if let failure = check("unfolded-line-14", ns.range(of: "\"tail\"").location) {
                failures.append(failure)
            }
        }
        guard failures.isEmpty else { return failures.joined(separator: " | ") }

        // Exact replay of the reported flow: fold the servers block, click its chevron to
        // unfold, then click at the end of the note.
        if let servers = textView.foldableRanges.first(where: { fold in
            let line = fold.headerLine
            let ns = textView.string as NSString
            guard let index = textView.cachedLineIndex(), line <= index.count else { return false }
            let start = index.starts[line - 1]
            let end = line < index.count ? index.starts[line] : ns.length
            return ns.substring(with: NSRange(location: start, length: max(0, end - start))).contains("servers")
        }) {
            textView.toggleFold(atLine: servers.headerLine)
            pump(0.4)
            textView.toggleFold(atLine: servers.headerLine)
            pump(0.4)
            textView.setSelectedRange(NSRange(location: ns.length, length: 0))
            pump(0.3)
            let band = textView.currentLineBandRect(in: textView.bounds)
            print("CARET_REPLAY band=\(band.map(NSStringFromRect) ?? "nil") rows=\(textView.visibleTextRows(in: textView.bounds).map { Int($0.rect.minY) }) selection=\(NSStringFromRange(textView.selectedRange()))")
            fflush(stdout)
            if let image = shownImage(of: window, content: host) {
                saveShot(image, name: "caret-after-unfold.png")
            }
            let replayBand = band
            guard let replayBand, replayBand.height <= 44 else {
                return "after unfolding, the caret band is \(band.map { Int($0.height) } ?? -1)pt"
            }
        }
        return nil
    }


    /// Sticky sections depend on the first visible source line. TextKit 1 has no viewport
    /// controller, so scrolling must still report a line.
    @MainActor
    private static func acceptViewportLine() -> String? {
        let code = (1...80).map { index -> String in
            if index == 1 { return "func long() {" }
            if index == 80 { return "}" }
            return "    step\(index)()"
        }.joined(separator: "\n") + "\n"
        guard let opened = acceptanceWindow(["code/long.swift": code]) else {
            return "could not open the scrolling window"
        }
        defer { closeAcceptance(opened) }
        let (_, session, _, host) = opened
        session.openRelative("code/long.swift")
        guard waitUntil(5, { session.buffer?.relativePath == "code/long.swift" }) else {
            return "the long file did not open"
        }
        session.selectViewMode(.source, source: "check")
        guard waitUntil(5, { findEditor(in: host) != nil }) else { return "no editor" }
        pump(0.5)
        guard let pane = findPane(in: host), let textView = pane.scrollView.documentView as? XYZMacTextView else {
            return "the editor is missing"
        }
        guard let scroll = textView.enclosingScrollView else { return "no scroll view" }
        let top = scroll.contentView.bounds
        scroll.contentView.scroll(to: NSPoint(x: top.minX, y: top.minY + 420))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(0.5)
        guard let line = textView.viewportLine(), line > 5 else {
            return "viewportLine() did not follow the scroll (line=\(String(describing: textView.viewportLine())))"
        }
        guard session.viewportLine == line else {
            return "the session kept viewportLine=\(session.viewportLine) while the editor reports \(line)"
        }
        return nil
    }


    /// The root collapse arrow and the first row's disclosure arrow must share a column.
    @MainActor
    private static func acceptSidebarArrows() -> String? {
        guard let opened = acceptanceWindow(["Folder/inside.md": "Note\n"]) else {
            return "could not open the sidebar window"
        }
        defer { closeAcceptance(opened) }
        let (_, _, _, host) = opened
        pump(0.5)
        host.layoutSubtreeIfNeeded()
        _ = waitUntil(4) { SidebarArrowCheck.measure(host: host).row != nil }
        let measured = SidebarArrowCheck.measure(host: host)
        print("SIDEBAR_ARROWS \(measured.text)")
        fflush(stdout)
        guard let header = measured.header, let row = measured.row else {
            return measured.text
        }
        guard abs(header - row) <= 2 else {
            return "the root arrow is \(Int(header))pt but row arrows sit at \(Int(row))pt"
        }
        if let image = shownImage(of: opened.2, content: host) {
            saveShot(image, name: "sidebar-arrows.png")
        }
        return nil
    }


    /// The theme wiring: every semantic color resolves, light and dark differ where they
    /// must, and the ink stays readable on the canvas in both appearances.
    @MainActor
    private static func acceptThemeColors() -> String? {
        func resolved(_ appearance: NSAppearance, _ role: KeyPath<XYZTheme, XYZColor>) -> NSColor {
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(xyz: XYZTheme.resolved(dark: dark)[keyPath: role])
        }
        func sample(_ appearance: NSAppearance) -> [NSColor] {
            var out: [NSColor] = []
            appearance.performAsCurrentDrawingAppearance {
                out = [NSColor.xyzEditor, NSColor.xyzSidebar, NSColor.xyzInk,
                       NSColor.xyzSecondaryText, NSColor.xyzTertiaryText, NSColor.xyzAccent,
                       NSColor.xyzSelection, NSColor.xyzSelectionText, NSColor.xyzCurrentLine,
                       NSColor.xyzDivider, NSColor.xyzHover, NSColor.xyzDisabledTint,
                       NSColor.xyzFindMatch, NSColor.xyzFindCurrent, NSColor.xyzFindToggleFill,
                       NSColor.xyzFindToggleInk, NSColor.xyzSyntax(.keyword), NSColor.xyzSyntax(.string)]
            }
            return out
        }
        guard let light = NSAppearance(named: .aqua), let dark = NSAppearance(named: .darkAqua) else {
            return "the two appearances do not exist"
        }
        let lightColors = sample(light)
        let darkColors = sample(dark)
        let modelLight = XYZTheme.light
        let modelDark = XYZTheme.dark
        guard lightColors.count == darkColors.count, lightColors.count == 18 else {
            return "expected 18 sampled colors, got \(lightColors.count)/\(darkColors.count)"
        }
        // The dynamic colors must resolve to the model values.
        guard resolved(light, \.editor).isClose(to: NSColor(xyz: modelLight.editor)),
              resolved(dark, \.editor).isClose(to: NSColor(xyz: modelDark.editor)) else {
            return "xyzEditor does not follow the model"
        }
        // Canvas and ink must differ across variants.
        guard NSColor(xyz: modelLight.editor).isDifferent(from: NSColor(xyz: modelDark.editor)) else {
            return "light and dark editors are identical"
        }
        guard NSColor(xyz: modelLight.ink).isDifferent(from: NSColor(xyz: modelDark.ink)) else {
            return "light and dark ink are identical"
        }
        // Syntax colors differ between variants.
        guard NSColor(xyz: modelLight.syntax.keyword).isDifferent(from: NSColor(xyz: modelDark.syntax.keyword)) else {
            return "light and dark keyword colors are identical"
        }
        return nil
    }

    /// Font checks use actual attributed runs and laid-out tab positions, not a second
    /// copy of the font-selection algorithm. This covers the live editor's TextKit 1.
    @MainActor
    private static func acceptTypography() -> String? {
        let source = "let value = 123\n\tvalue\n  value\n \tvalue\n中文 English 😀\n"
        for size: CGFloat in [11, 16, 24] {
            for mono in [false, true] {
                var style = XYZEditorStyle()
                style.fontSize = size
                style.monospaced = mono
                style.lineHeight = 1.0 // Stress CJK metrics without clipping tall glyphs.
                let view = XYZMacTextView(usingTextLayoutManager: false)
                view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
                view.style = style
                view.string = source
                EditorTypography.apply(to: view, style: style, markup: false, language: .swift, edited: nil)
                guard let storage = view.textStorage, let manager = view.layoutManager, let container = view.textContainer else {
                    return "missing TextKit 1 storage"
                }
                let expected = EditorTypography.baseFont(style)
                var mismatched = false
                // AppKit may materialize CJK/emoji fallback runs in storage. Only the
                // Latin code must retain the primary face; fallback glyphs must not.
                let latinRange = NSRange(location: 0, length: (source as NSString).range(of: "中文").location)
                storage.enumerateAttribute(.font, in: latinRange) { value, _, _ in
                    guard let font = value as? NSFont else { mismatched = true; return }
                    if font.fontName != expected.fontName || font.pointSize != size { mismatched = true }
                }
                guard !mismatched else { return "syntax changed the face/size: mono=\(mono) \(size)" }
                guard view.string == source else { return "typography changed source text" }
                let paragraph = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
                let step = ("  " as NSString).size(withAttributes: [.font: expected]).width
                guard paragraph.tabStops.isEmpty, abs(paragraph.defaultTabInterval - step) < 0.01,
                      paragraph.maximumLineHeight == 0 else { return "incorrect tab stops or clamped glyph height" }
                manager.ensureLayout(for: container)
                let ns = source as NSString
                let offsets = ["\tvalue", "  value", " \tvalue"].map {
                    let range = ns.range(of: $0)
                    return range.location + ($0 as NSString).length - 5
                }
                let positions = offsets.map { offset -> CGFloat in
                    let glyph = manager.glyphIndexForCharacter(at: offset)
                    return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                        + manager.location(forGlyphAt: glyph).x
                }
                guard positions.allSatisfy({ abs($0 - positions[0]) < 0.1 }) else {
                    return "tab/space grid differs for mono=\(mono) \(size): \(positions)"
                }
                // Fence blocks retain full source size and their own measured tab stops.
                view.string = "```swift\n\tlet value = 123\n```\n"
                EditorTypography.apply(to: view, style: style, markup: true, edited: nil)
                let body = (view.string as NSString).range(of: "let")
                let code = EditorTypography.codeFont(style, inline: false)
                guard let actual = storage.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont,
                      actual.pointSize == size, actual.fontName == code.fontName,
                      let blockParagraph = storage.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle,
                      abs(blockParagraph.minimumLineHeight - max(EditorTypography.naturalLineHeight(code), ceil(size * XYZEditorStyle.codeLineHeight(forProse: style.lineHeight)))) < 0.01,
                      abs(blockParagraph.defaultTabInterval - ("  " as NSString).size(withAttributes: [.font: code]).width) < 0.01 else {
                    return "fenced code has a different size/tab grid"
                }
            }
        }
        // Line spacing is the one typographic preference: prose follows it exactly,
        // and fenced code keeps a fixed step tighter.
        for spacing: CGFloat in [1.0, 1.3, 1.7, 2.0] {
            var style = XYZEditorStyle()
            style.lineHeight = spacing
            let view = XYZMacTextView(usingTextLayoutManager: false)
            view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
            view.style = style
            view.string = "prose line\n```swift\nlet value = 123\n```\n"
            EditorTypography.apply(to: view, style: style, markup: true, edited: nil)
            guard let storage = view.textStorage else { return "missing storage for line spacing" }
            let ns = view.string as NSString
            let prose = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let expectedProse = max(EditorTypography.naturalLineHeight(EditorTypography.baseFont(style)), ceil(style.fontSize * spacing))
            let codeLine = XYZEditorStyle.codeLineHeight(forProse: spacing)
            let expectedCode = max(EditorTypography.naturalLineHeight(EditorTypography.codeFont(style, inline: false)), ceil(style.fontSize * codeLine))
            let bodyIndex = ns.range(of: "let").location
            let fence = storage.attribute(.paragraphStyle, at: bodyIndex, effectiveRange: nil) as? NSParagraphStyle
            guard let prose, abs(prose.minimumLineHeight - expectedProse) < 0.01,
                  let fence, abs(fence.minimumLineHeight - expectedCode) < 0.01 else {
                return "line spacing preference was not applied at \(spacing)"
            }
        }
        for mono in [false, true] {
            let style = XYZEditorStyle(monospaced: mono)
            let font = EditorTypography.headingFont(style, level: 2)
            let resolved = CTFontCreateForString(font as CTFont, "中文" as CFString, CFRange(location: 0, length: 2))
            guard CTFontCopyPostScriptName(resolved) as String == font.fontName else {
                return "Chinese heading differs from Latin face/weight"
            }
        }
        guard XYZMacTextView.indentLevels(" \t \tvalue") == 2 else { return "mixed-indent tab stops drift" }
        return nil
    }

    @MainActor
    private static func acceptBundledFonts() -> String? {
        AppFonts.register()
        for face in AppFonts.faces {
            guard let font = NSFont(name: face.postScript, size: 16),
                  let actual = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL,
                  let expected = AppFonts.url(face.file),
                  actual.standardizedFileURL == expected.standardizedFileURL else {
                return "bundled face missing: \(face.file)"
            }
            let cjk = CTFontCreateForString(font as CTFont, "中文" as CFString, CFRange(location: 0, length: 2))
            guard CTFontCopyPostScriptName(cjk) as String == face.postScript else {
                return "mixed text fell back to a different family: \(face.file)"
            }
        }
        guard EditorTypography.baseFont(.markdown).fontName == AppFonts.name(monospaced: false),
              EditorTypography.codeFont(.markdown).fontName == AppFonts.name(monospaced: true) else {
            return "fixed font roles did not resolve"
        }
        for address in ["xyz-font://bundled/../../etc/passwd", "xyz-font://other/SarasaGothicSC-Regular.ttf", "xyz-font://bundled/SarasaGothicSC-Regular.ttf?file=secret"] {
            guard AppFonts.resource(for: URL(string: address)!) == nil else { return "font resource escaped the allowlist" }
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(BundledFontSchemeHandler(), forURLScheme: AppFonts.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 480), configuration: configuration)
        web.loadHTMLString(PreviewPage.shell(css: PreviewStyles.load(), html: "<p>中文 prose</p><ul><li>Mixed 中英文列表</li></ul><pre><code>let value = 123</code></pre>", theme: "light", prefs: PreviewPrefs()), baseURL: nil)
        guard waitUntil(8, { !web.isLoading && web.url != nil }) else { return "Reading font page did not load" }
        var result: String?
        web.callAsyncJavaScript("""
            for (const family of ['XYZ Prose', 'XYZ Code']) {
              for (const weight of ['400', '600']) {
                const faces = await document.fonts.load(weight + ' 16px "' + family + '"', '中文 English');
                if (!faces.length || faces.some(f => f.status !== 'loaded')) return 'missing face: ' + family + weight;
              }
            }
            const code = getComputedStyle(document.querySelector('pre code')).fontFamily;
            const prose = getComputedStyle(document.querySelector('p')).fontFamily;
            if (!code.includes('XYZ Code') || !prose.includes('XYZ Prose')) return 'font role mismatch';
            const ratio = () => parseFloat(getComputedStyle(document.body).lineHeight) / parseFloat(getComputedStyle(document.body).fontSize);
            if (Math.abs(ratio() - 1.7) > 0.01) return 'incorrect default reading rhythm';
            setPrefs(16, 1.35);
            if (Math.abs(ratio() - 1.35) > 0.01) return 'reading ignored the line spacing preference';
            setPrefs(16, 1.7);
            // Typography must not introduce a reading-column width cap, at any zoom.
            for (const size of [11, 16, 24]) {
              setPrefs(size, 1.7);
              const article = document.querySelector('article').getBoundingClientRect();
              const viewport = document.documentElement.clientWidth;
              if (Math.abs(article.width - viewport) > 1 || Math.abs(article.left) > 1) return 'reading width was capped or centered';
              const padding = parseFloat(getComputedStyle(document.querySelector('article')).paddingLeft);
              if (Math.abs(padding - Math.min(56, Math.max(16, window.innerWidth * 0.04))) > 1) return 'original content inset changed';
            }
            setPrefs(16, 1.7);
            if (parseFloat(getComputedStyle(document.querySelector('li')).marginBottom) < 4) return 'list spacing too tight';
            const c = document.createElement('canvas').getContext('2d');
            c.font = '16px "XYZ Code"';
            if (Math.abs(c.measureText('中').width - c.measureText('MM').width) > 0.1) return 'bilingual code columns differ';
            return 'pass';
            """, arguments: [:], in: nil, in: .page) { completion in
                switch completion {
                case .success(let value): result = value as? String ?? "invalid web result"
                case .failure(let error): result = error.localizedDescription
                }
            }
        guard waitUntil(10, { result != nil }) else { return "web fonts did not finish loading" }
        return result == "pass" ? nil : result
    }

    private static func runAcceptanceGestures() -> String? {
        let failures = MainActor.assumeIsolated { () -> [String] in
            var failed: [String] = []
            func record(_ name: String, _ failure: String?) {
                if let failure {
                    let line = "ACCEPTANCE case=\(name) result=fail \(failure)"
                    print(line)
                    fflush(stdout)
                    failed.append(line)
                } else {
                    print("ACCEPTANCE case=\(name) result=pass")
                    fflush(stdout)
                }
            }
            record("create-file", acceptCreateFile())
            record("create-folder", acceptCreateFolder())
            record("nested-file", acceptNestedFile())
            record("refresh", acceptRefresh())
            record("collapse-header", acceptCollapseHeader())
            record("dividers", acceptDividers())
            record("mode-labels", acceptModeLabels())
            record("empty-line-prefs", acceptEmptyLine())
            record("code-folding", acceptCodeFolding())
            record("markdown-folding", acceptMarkdownFolding())
            record("editor-folding", acceptEditorFolding())
            record("editor-folding-caret", acceptFoldingCaret())
            record("editor-caret-band", acceptCaretBand())
            record("editor-viewport-line", acceptViewportLine())
            record("sidebar-arrows", acceptSidebarArrows())
            record("theme-colors", acceptThemeColors())
            record("typography", acceptTypography())
            record("bundled-fonts", acceptBundledFonts())
            if failed.isEmpty {
                print("ACCEPTANCE_OK")
            } else {
                print("ACCEPTANCE_FAIL \(failed.count)")
            }
            fflush(stdout)
            return failed
        }
        return failures.isEmpty ? nil : failures.joined(separator: " | ")
    }

    @MainActor
    private static func acceptCreateFile() -> String? {
        guard let opened = acceptanceWindow(["Untitled.md": "Keepme\n"]) else {
            return "could not open the create-file window"
        }
        defer { closeAcceptance(opened) }
        let (root, session, window, host) = opened
        guard waitUntil(4, { row(explorerOutline(in: host) ?? NSOutlineView(), titled: "Untitled.md") != nil }),
              let outline = explorerOutline(in: host),
              let button = labeledControl(in: host, "New File"),
              let header = explorerHeader(in: host) else {
            return "create-file controls were not ready labels=\(accessibilityLabels(in: host).prefix(12).joined(separator: "|"))"
        }
        let before = directoryNames(root)
        guard trackingClick(button) else { return "New File click was not delivered" }
        pump(0.2)
        guard headerState(header) == "Expanded" else { return "New File toggled the root header" }
        guard waitUntil(6, { createdMarkdown(in: root, besides: before) != nil }),
              let created = createdMarkdown(in: root, besides: before) else {
            return "New File did not create a file listing=\(directoryNames(root).joined(separator: ","))"
        }
        if created == "Untitled.md" || readText(root.appendingPathComponent("Untitled.md")) != "Keepme\n" {
            return "New File overwrote Untitled.md"
        }
        guard waitUntil(3, { renamingText(in: window)?.contains(created.replacingOccurrences(of: ".md", with: "")) == true }) else {
            return "the new file did not offer a name to cancel"
        }
        guard sendEscape(to: window) else { return "Escape was not delivered" }
        pump(0.2)
        if renamingText(in: window) != nil { return "cancel did not leave the name field" }
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(created).path) {
            return "cancel removed the new file"
        }
        _ = outline
        _ = session
        return nil
    }

    @MainActor
    private static func acceptCreateFolder() -> String? {
        guard let opened = acceptanceWindow(["Notes/nested.md": "Nestedline\n"]) else {
            return "could not open the create-folder window"
        }
        defer { closeAcceptance(opened) }
        let (root, _, window, host) = opened
        guard waitUntil(4, { row(explorerOutline(in: host) ?? NSOutlineView(), titled: "Notes") != nil }),
              let button = labeledControl(in: host, "New Folder"),
              let header = explorerHeader(in: host) else {
            return "create-folder controls were not ready"
        }
        let before = directoryNames(root)
        guard trackingClick(button) else { return "New Folder click was not delivered" }
        pump(0.2)
        guard headerState(header) == "Expanded" else { return "New Folder toggled the root header" }
        guard waitUntil(4, {
            directoryNames(root).contains { $0.contains("Untitled Folder") && !before.contains($0) }
        }) else { return "New Folder did not create a folder" }
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes").path) {
            return "New Folder replaced Notes"
        }
        guard waitUntil(3, { renamingText(in: window)?.contains("Untitled Folder") == true }) else {
            return "the new folder did not offer a name to cancel"
        }
        guard sendEscape(to: window) else { return "Escape was not delivered" }
        pump(0.2)
        if renamingText(in: window) != nil { return "cancel did not leave the folder name" }
        return nil
    }

    /// Known limit: a synthetic click on a nested file does not select the row. Recorded, not treated as a product change.
    @MainActor
    private static func acceptNestedFile() -> String? {
        guard let opened = acceptanceWindow(["Notes/Inner/deep.md": "Deepline\n"]) else {
            return "could not open the nested-file window"
        }
        defer { closeAcceptance(opened) }
        let (_, session, _, host) = opened
        guard let outline = waitOutline(host, row: "Notes") else { return "Notes was not listed" }
        guard let notesRow = row(outline, titled: "Notes"), trackingClick(outline, row: notesRow, disclosure: true) else {
            return "Notes disclosure click failed"
        }
        guard waitUntil(3, { row(outline, titled: "Inner") != nil }),
              let innerRow = row(outline, titled: "Inner"),
              trackingClick(outline, row: innerRow, disclosure: true) else {
            return "Inner did not expand"
        }
        guard waitUntil(3, { row(outline, titled: "deep.md") != nil }),
              let deepRow = row(outline, titled: "deep.md") else {
            return "deep.md row missing"
        }
        guard trackingClick(outline, row: deepRow, disclosure: false) else {
            return "deep.md click was outside the visible row \(rowVisibility(outline, deepRow))"
        }
        guard waitUntil(4, { session.buffer?.text.contains("Deepline") == true }) else {
            let selected = outline.selectedRow
            let selectedTitle = selected >= 0 ? rowTitle(outline, selected) : "none"
            return "clicking deep.md did not open it selected=\(selectedTitle) buffer=\(session.buffer?.relativePath ?? "nil")"
        }
        return nil
    }

    @MainActor
    private static func acceptRefresh() -> String? {
        guard let opened = acceptanceWindow(["Notes/nested.md": "Nestedline\n"]) else {
            return "could not open the refresh window"
        }
        defer { closeAcceptance(opened) }
        let (root, session, _, host) = opened
        guard let outline = waitOutline(host, row: "Notes"),
              let notesRow = row(outline, titled: "Notes") else { return "Notes was not listed" }
        guard trackingClick(outline, row: notesRow, disclosure: true) else { return "Notes disclosure click failed" }
        guard waitUntil(3, { row(outline, titled: "nested.md") != nil }) else { return "Notes did not expand" }
        let expanded = session.expanded
        try? "Extra\n".write(to: root.appendingPathComponent("Notes/extra.md"), atomically: true, encoding: .utf8)
        guard let refresh = labeledControl(in: host, "Refresh Explorer") else { return "Refresh was not found" }
        guard trackingClick(refresh) else { return "Refresh click was not delivered" }
        guard waitUntil(4, { row(outline, titled: "extra.md") != nil }) else { return "Refresh did not show extra.md" }
        if session.expanded != expanded { return "Refresh changed which folders are open" }
        if explorerHeader(in: host).map(headerState) != "Expanded" { return "Refresh toggled the root header" }
        return nil
    }

    @MainActor
    private static func acceptCollapseHeader() -> String? {
        guard let opened = acceptanceWindow(["Notes/Inner/deep.md": "Deepline\n"]) else {
            return "could not open the collapse window"
        }
        defer { closeAcceptance(opened) }
        let (root, session, _, host) = opened
        guard let outline = waitOutline(host, row: "Notes"),
              let notesRow = row(outline, titled: "Notes"),
              trackingClick(outline, row: notesRow, disclosure: true),
              waitUntil(3, { row(outline, titled: "Inner") != nil }),
              let innerRow = row(outline, titled: "Inner"),
              trackingClick(outline, row: innerRow, disclosure: true),
              waitUntil(3, { row(outline, titled: "deep.md") != nil }) else {
            return "the folders did not expand before Collapse All"
        }
        session.openRelative("Notes/Inner/deep.md")
        guard waitUntil(4, { session.buffer?.text.contains("Deepline") == true }) else {
            return "setup could not open the nested note without the row click"
        }
        guard let collapse = labeledControl(in: host, "Collapse All"),
              let header = explorerHeader(in: host),
              let newFile = labeledControl(in: host, "New File") else {
            return "collapse controls were not ready"
        }
        guard trackingClick(collapse) else { return "Collapse All click was not delivered" }
        guard waitUntil(3, { row(outline, titled: "deep.md") == nil }) else { return "Collapse All left descendants open" }
        if session.buffer?.text.contains("Deepline") != true { return "Collapse All closed the open file" }
        if !session.expanded.isEmpty { return "Collapse All left a folder expanded" }
        if headerState(header) != "Expanded" { return "Collapse All collapsed the root header" }
        guard plainClick(header, x: 24) else { return "root header click was not delivered" }
        guard waitUntil(2, { headerState(header) == "Collapsed" }) else { return "the root header did not collapse" }
        if session.buffer?.text.contains("Deepline") != true { return "collapsing the header closed the file" }
        let namesBefore = directoryNames(root)
        guard trackingClick(newFile) else { return "New File click while collapsed was not delivered" }
        pump(0.2)
        if headerState(header) != "Collapsed" { return "New File expanded the collapsed header" }
        _ = namesBefore
        guard plainClick(header, x: 24) else { return "expanding the header failed" }
        guard waitUntil(2, { headerState(header) == "Expanded" }) else { return "the root header stayed collapsed" }
        if row(outline, titled: "deep.md") != nil { return "expanding the header reopened collapsed descendants" }
        return nil
    }

    @MainActor
    private static func acceptDividers() -> String? {
        guard let opened = acceptanceWindow(["note.md": "Dividernote\n"]) else {
            return "could not open the divider window"
        }
        defer { closeAcceptance(opened) }
        let (root, session, _, host) = opened
        session.openRelative("note.md")
        guard waitUntil(4, { session.buffer?.text.contains("Dividernote") == true }) else {
            return "setup could not show the divider note"
        }
        guard let split = findSplit(in: host),
              let left = identified(in: host, "xyz.divider.left"),
              let right = identified(in: host, "xyz.divider.right") else {
            return "a production divider is missing"
        }
        let textBefore = session.buffer?.text ?? ""
        let expandedBefore = session.expanded
        let rootBefore = session.rootExpanded
        let selectedBefore = session.selectedPath
        guard doubleClick(left) else { return "left divider double-click was not delivered" }
        pump(0.2)
        let fittedSidebar = split.testingSidebarFrame().width
        let expectedSidebar = SidebarFit.sidebar(
            content: split.measureSidebar(),
            window: split.bounds.width,
            outline: split.testingOutlineFrame().width,
            outlineShown: split.testingOutlineFrame().width > 1
        )
        if abs(fittedSidebar - expectedSidebar) > 1.5 {
            return "left double-click width \(fittedSidebar) expected \(expectedSidebar)"
        }
        guard doubleClick(left) else { return "second left double-click was not delivered" }
        pump(0.1)
        if abs(split.testingSidebarFrame().width - fittedSidebar) > 1 { return "left double-click was not idempotent" }
        guard drag(left, by: 48) else { return "left divider drag was not delivered" }
        pump(0.1)
        let afterSidebar = split.testingSidebarFrame().width
        if abs(afterSidebar - fittedSidebar) < 8 { return "dragging the left divider left the sidebar at \(afterSidebar)" }
        if afterSidebar < SidebarFit.sidebarMinimum - 1 { return "the sidebar drag went below the minimum" }
        host.layoutSubtreeIfNeeded()
        if abs(split.testingSidebarFrame().width - afterSidebar) > 1 { return "the sidebar width did not stay after layout" }
        guard split.testingOutlineFrame().width > 1 else { return "the outline divider is not on screen" }
        guard doubleClick(right) else { return "right divider double-click was not delivered" }
        pump(0.2)
        let fittedOutline = split.testingOutlineFrame().width
        let expectedOutline = SidebarFit.outline(
            content: split.measureOutline(),
            window: split.bounds.width,
            sidebar: split.testingSidebarFrame().width,
            sidebarShown: true
        )
        if abs(fittedOutline - expectedOutline) > 1.5 {
            return "right double-click width \(fittedOutline) expected \(expectedOutline)"
        }
        guard doubleClick(right) else { return "second right double-click was not delivered" }
        pump(0.1)
        if abs(split.testingOutlineFrame().width - fittedOutline) > 1 { return "right double-click was not idempotent" }
        guard drag(right, by: -40) else { return "right divider drag was not delivered" }
        pump(0.15)
        let afterOutline = split.testingOutlineFrame().width
        if abs(afterOutline - fittedOutline) < 8 { return "dragging the right divider left the outline at \(afterOutline)" }
        if afterOutline < SidebarFit.outlineMinimum - 1 { return "the outline drag went below the minimum" }
        if split.testingDetailFrame().width < SidebarFit.editorMinimum - 1 { return "the editor was left under its minimum" }
        host.layoutSubtreeIfNeeded()
        if abs(split.testingOutlineFrame().width - afterOutline) > 1 { return "the outline width did not stay after layout" }
        let restored = WorkspaceSession(rootURL: root, bookmark: nil)
        let restoredWidth = restored.outlineWidth
        restored.shutdown()
        if abs(restoredWidth - afterOutline) > 1.5 {
            return "the next window did not restore the outline width \(restoredWidth) vs \(afterOutline)"
        }
        if session.buffer?.text != textBefore || session.expanded != expandedBefore
            || session.rootExpanded != rootBefore || session.selectedPath != selectedBefore {
            return "a divider gesture changed the file, the selection, or expansion"
        }
        return nil
    }

    @MainActor
    private static func acceptModeLabels() -> String? {
        guard let opened = acceptanceWindow(["note.md": "Modeline\n"]) else {
            return "could not open the mode window"
        }
        defer { closeAcceptance(opened) }
        let (_, session, window, host) = opened
        session.openRelative("note.md")
        guard waitUntil(4, { session.buffer?.text.contains("Modeline") == true }) else {
            return "setup could not show the mode note"
        }
        pump(0.3)
        guard EditorCommands.shared.target != nil else {
            return "the View menu target was not attached to this window"
        }
        EditorCommands.shared.selectReading(nil)
        pump(0.35)
        if let failure = assertModeWeight(window, word: "Read-only", appearance: .aqua) { return failure }
        if let failure = assertModeWeight(window, word: "Read-only", appearance: .darkAqua) { return failure }
        EditorCommands.shared.selectSource(nil)
        pump(0.35)
        if let failure = assertModeWeight(window, word: "Editing", appearance: .aqua) { return failure }
        if let failure = assertModeWeight(window, word: "Editing", appearance: .darkAqua) { return failure }
        window.appearance = NSAppearance(named: .aqua)
        NSApp.appearance = window.appearance
        _ = host
        return nil
    }

    @MainActor
    private static func acceptEmptyLine() -> String? {
        let defaults = UserDefaults.standard
        let lineKey = XYZEditorStyle.lineNumbersKey
        let readingKey = XYZEditorStyle.readingLineNumbersKey
        let previousLine = defaults.object(forKey: lineKey)
        let previousReading = defaults.object(forKey: readingKey)
        defaults.set(false, forKey: lineKey)
        defaults.set(true, forKey: readingKey)
        defer {
            if let previousLine { defaults.set(previousLine, forKey: lineKey) }
            else { defaults.removeObject(forKey: lineKey) }
            if let previousReading { defaults.set(previousReading, forKey: readingKey) }
            else { defaults.removeObject(forKey: readingKey) }
        }
        guard let opened = acceptanceWindow(["empty.md": "", "note.md": "Prefnote\n"]) else {
            return "could not open the empty-line window"
        }
        defer { closeAcceptance(opened) }
        let (_, session, window, host) = opened
        session.openRelative("empty.md")
        guard waitUntil(4, { session.buffer?.relativePath == "empty.md" }) else {
            return "setup could not open the empty note"
        }
        pump(0.2)
        guard EditorCommands.shared.target != nil else { return "the View menu target was not attached" }
        EditorCommands.shared.selectSource(nil)
        pump(0.35)
        host.layoutSubtreeIfNeeded()
        guard let pane = findPane(in: host),
              let textView = pane.scrollView.documentView as? XYZMacTextView,
              textView.string.isEmpty else {
            return "Editing did not show the empty note"
        }
        if pane.gutter.isHidden || pane.gutter.frame.width < 20 {
            return "a saved off preference hid Editing numbers"
        }
        let numbers = pane.gutter.testingSnapshot().rows.filter(\.shows).map(\.line)
        if numbers != [1] { return "an empty note showed \(numbers) instead of line 1" }
        EditorCommands.shared.selectReading(nil)
        pump(0.35)
        if let readingPane = findPane(in: host), !readingPane.gutter.isHidden, readingPane.gutter.frame.width > 8 {
            return "Reading kept a gutter"
        }
        if menuHasLineNumberSetting() { return "a line-number menu item is still present" }
        if defaults.bool(forKey: lineKey) { return "showing numbers turned the old preference on" }
        if defaults.bool(forKey: readingKey) == false { return "the old Reading preference was cleared" }
        _ = window
        return nil
    }

    @MainActor
    private static func acceptanceWindow(_ files: [String: String]) -> (URL, WorkspaceSession, NSWindow, NSView)? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xyz-accept-\(UUID().uuidString)", isDirectory: true)
        do {
            for (path, text) in files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            return nil
        }
        // Without a bookmark every file opens read-only: the gutter and the fold chevrons
        // never mount, and an editable-window bug cannot be reproduced here.
        let session = WorkspaceSession(rootURL: root, bookmark: WorkspaceBookmarks.capture(root))
        let controller = WorkspaceWindowController(session: session)
        guard let window = controller.window, let host = window.contentView else {
            session.shutdown()
            try? FileManager.default.removeItem(at: root)
            return nil
        }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        pump(0.25)
        return (root, session, window, host)
    }

    @MainActor
    private static func closeAcceptance(_ opened: (URL, WorkspaceSession, NSWindow, NSView)) {
        opened.1.shutdown()
        opened.2.close()
        try? FileManager.default.removeItem(at: opened.0)
    }

    @MainActor
    private static func waitOutline(_ host: NSView, row title: String) -> NSOutlineView? {
        guard waitUntil(4, { row(explorerOutline(in: host) ?? NSOutlineView(), titled: title) != nil }) else { return nil }
        return explorerOutline(in: host)
    }

    private static func directoryNames(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
    }

    private static func createdMarkdown(in root: URL, besides existing: [String]) -> String? {
        directoryNames(root).first { $0.hasSuffix(".md") && !existing.contains($0) }
    }

    private static func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func waitUntil(_ seconds: TimeInterval, _ check: () -> Bool) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if check() { return true }
            pump(0.05)
        }
        return check()
    }

    private static func explorerOutline(in root: NSView) -> NSOutlineView? {
        let label = String(localized: "Folder contents")
        var found: NSOutlineView?
        func walk(_ view: NSView) {
            if found == nil, let outline = view as? NSOutlineView, outline.accessibilityLabel() == label {
                found = outline
            }
            for child in view.subviews where found == nil { walk(child) }
        }
        walk(root)
        return found
    }

    private static func labeledControl(in root: NSView, _ title: String) -> NSView? {
        let label = String(localized: String.LocalizationValue(title))
        var found: NSView?
        func walk(_ view: NSView) {
            if found == nil, view.accessibilityLabel() == label, view.accessibilityRole() == .button {
                found = view
            }
            for child in view.subviews where found == nil { walk(child) }
        }
        walk(root)
        return found
    }

    private static func explorerHeader(in root: NSView) -> NSView? {
        let expanded = String(localized: "Expanded")
        let collapsed = String(localized: "Collapsed")
        var found: NSView?
        func walk(_ view: NSView) {
            let label = view.accessibilityLabel() ?? ""
            if found == nil, view.accessibilityRole() != .button, label.contains(expanded) || label.contains(collapsed) {
                found = view
            }
            for child in view.subviews where found == nil { walk(child) }
        }
        walk(root)
        return found
    }

    private static func headerState(_ header: NSView) -> String {
        let label = header.accessibilityLabel() ?? ""
        if label.contains(String(localized: "Collapsed")) { return "Collapsed" }
        if label.contains(String(localized: "Expanded")) { return "Expanded" }
        return ""
    }

    private static func headerShowsCount(_ header: NSView) -> Bool {
        var count = false
        func walk(_ view: NSView) {
            if let field = view as? NSTextField {
                let text = field.stringValue.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, text.allSatisfy(\.isNumber) { count = true }
            }
            for child in view.subviews { walk(child) }
        }
        walk(header)
        return count
    }

    private static func identified(in root: NSView, _ identifier: String) -> NSView? {
        var found: NSView?
        func walk(_ view: NSView) {
            if found == nil, view.accessibilityIdentifier() == identifier { found = view }
            for child in view.subviews where found == nil { walk(child) }
        }
        walk(root)
        return found
    }

    private static func row(_ outline: NSOutlineView, titled name: String) -> Int? {
        for index in 0..<outline.numberOfRows {
            if rowTitle(outline, index) == name { return index }
        }
        return nil
    }

    private static func rowTitle(_ outline: NSOutlineView, _ index: Int) -> String {
        guard let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: true) else { return "" }
        return firstFieldText(in: cell)
    }

    private static func firstFieldText(in view: NSView) -> String {
        if let field = view as? NSTextField {
            let text = field.stringValue
            if !text.isEmpty { return text }
        }
        for child in view.subviews {
            let text = firstFieldText(in: child)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func accessibilityLabels(in root: NSView?) -> [String] {
        guard let root else { return [] }
        var labels: [String] = []
        func walk(_ view: NSView) {
            if let label = view.accessibilityLabel(), !label.isEmpty { labels.append(label) }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return labels
    }

    private static func renamingText(in window: NSWindow) -> String? {
        guard let editor = window.firstResponder as? NSTextView else { return nil }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("Untitled") else { return nil }
        return text
    }

    private static func sendEscape(to window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else { return false }
        window.sendEvent(event)
        return true
    }

    private static func trackingClick(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        window.makeKeyAndOrderFront(nil)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let down = mouseEvent(.leftMouseDown, at: point, window: window, clickCount: 1, eventNumber: 0),
              let up = mouseEvent(.leftMouseUp, at: point, window: window, clickCount: 1, eventNumber: 0) else { return false }
        NSApp.postEvent(up, atStart: true)
        view.mouseDown(with: down)
        return true
    }

    /// A file cell can be wider than the sidebar. Its midpoint then lies over the editor, so a window hit test never reaches the row.
    /// The disclosure triangle is narrow and already expands when the window delivers the click, so that path stays.
    private static func trackingClick(_ outline: NSOutlineView, row: Int, disclosure: Bool) -> Bool {
        guard let window = outline.window, row >= 0, row < outline.numberOfRows else { return false }
        outline.scrollRowToVisible(row)
        outline.layoutSubtreeIfNeeded()
        let rect = disclosure ? outline.frameOfOutlineCell(atRow: row) : outline.frameOfCell(atColumn: 0, row: row)
        let visible = outline.visibleRect
        let target = rect.intersection(visible)
        guard target.width > 4, target.height > 4 else { return false }
        let local = disclosure
            ? NSPoint(x: target.midX, y: target.midY)
            : NSPoint(x: min(target.maxX - 4, target.minX + 28), y: target.midY)
        let point = outline.convert(local, to: nil)
        return postUpThenDown(window: window, point: point, clickCount: 1)
    }

    private static func rowVisibility(_ outline: NSOutlineView, _ row: Int) -> String {
        guard row >= 0, row < outline.numberOfRows else { return "missing" }
        let rect = outline.frameOfCell(atColumn: 0, row: row)
        let visible = outline.visibleRect
        return "cell=\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)) visible=\(Int(visible.width))x\(Int(visible.height))"
    }

    private static func plainClick(_ view: NSView, x: CGFloat) -> Bool {
        guard let window = view.window else { return false }
        let point = view.convert(NSPoint(x: x, y: view.bounds.midY), to: nil)
        guard let down = mouseEvent(.leftMouseDown, at: point, window: window, clickCount: 1, eventNumber: 41),
              let up = mouseEvent(.leftMouseUp, at: point, window: window, clickCount: 1, eventNumber: 42) else { return false }
        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    private static func doubleClick(_ view: NSView) -> Bool {
        guard let window = view.window else { return false }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let down = mouseEvent(.leftMouseDown, at: point, window: window, clickCount: 2, eventNumber: 51),
              let up = mouseEvent(.leftMouseUp, at: point, window: window, clickCount: 2, eventNumber: 52) else { return false }
        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    private static func drag(_ view: NSView, by dx: CGFloat) -> Bool {
        guard let window = view.window else { return false }
        let start = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let end = NSPoint(x: start.x + dx, y: start.y)
        guard let down = mouseEvent(.leftMouseDown, at: start, window: window, clickCount: 1, eventNumber: 61),
              let moved = mouseEvent(.leftMouseDragged, at: end, window: window, clickCount: 1, eventNumber: 62),
              let up = mouseEvent(.leftMouseUp, at: end, window: window, clickCount: 1, eventNumber: 63) else { return false }
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(moved, atStart: true)
        window.sendEvent(down)
        return true
    }

    private static func postUpThenDown(window: NSWindow, point: NSPoint, clickCount: Int) -> Bool {
        guard let down = mouseEvent(.leftMouseDown, at: point, window: window, clickCount: clickCount, eventNumber: 21),
              let up = mouseEvent(.leftMouseUp, at: point, window: window, clickCount: clickCount, eventNumber: 22) else { return false }
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        return true
    }

    private static var gestureEventNumber = 100

    private static func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        window: NSWindow,
        clickCount: Int,
        eventNumber: Int
    ) -> NSEvent? {
        gestureEventNumber += 1
        _ = eventNumber
        return NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: gestureEventNumber,
            clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    private static func assertModeWeight(_ window: NSWindow, word: String, appearance: NSAppearance.Name) -> String? {
        window.appearance = NSAppearance(named: appearance)
        NSApp.appearance = window.appearance
        pump(0.25)
        window.displayIfNeeded()
        let wanted = String(localized: String.LocalizationValue(word))
        let matches = modeFonts(in: window.contentView, word: wanted)
        if let weight = matches.first {
            if weight < 7 {
                return "gesture: \(wanted) \(appearance.rawValue) weight \(weight) is not bold"
            }
            return nil
        }
        guard let label = labeledExact(window.contentView, wanted),
              let image = shownImage(of: window, content: window.contentView ?? label),
              let crop = cropWindowImage(image, view: label, window: window) else {
            let classes = viewClasses(in: window.contentView).prefix(24).joined(separator: ",")
            return "gesture: \(wanted) \(appearance.rawValue) text was not measurable views=\(classes)"
        }
        let dark = appearance == .darkAqua
        let bold = textInkRatio(wanted, weight: .bold, dark: dark)
        let regular = textInkRatio(wanted, weight: .regular, dark: dark)
        let seen = imageInkRatio(crop, dark: dark)
        if seen < min(bold, regular) * 0.45 {
            return "gesture: \(wanted) \(appearance.rawValue) weight was not measurable ink=\(seen) bold=\(bold) regular=\(regular)"
        }
        if abs(seen - bold) > abs(seen - regular) {
            return "gesture: \(wanted) \(appearance.rawValue) ink \(seen) is closer to regular \(regular) than bold \(bold)"
        }
        return nil
    }

    private static func labeledExact(_ root: NSView?, _ word: String) -> NSView? {
        guard let root else { return nil }
        if root.accessibilityLabel() == word { return root }
        for child in root.subviews {
            if let found = labeledExact(child, word) { return found }
        }
        return nil
    }

    private static func textInkRatio(_ word: String, weight: NSFont.Weight, dark: Bool) -> CGFloat {
        _ = dark
        let font = NSFont.systemFont(ofSize: 11, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: dark ? NSColor.white : NSColor.black,
        ]
        let size = (word as NSString).size(withAttributes: attributes)
        let width = max(1, Int(ceil(size.width)))
        let height = max(1, Int(ceil(size.height)))
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
        ) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        (word as NSString).draw(at: .zero, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        var ink = 0
        var seen = 0
        for y in 0..<height {
            for x in 0..<width {
                seen += 1
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.35 { ink += 1 }
            }
        }
        guard seen > 0 else { return 0 }
        return CGFloat(ink) / CGFloat(seen)
    }

    private static func imageInkRatio(_ image: CGImage, dark: Bool) -> CGFloat {
        let rep = NSBitmapImageRep(cgImage: image)
        let startX = rep.pixelsWide / 3
        var ink = 0
        var seen = 0
        var y = 0
        while y < rep.pixelsHigh {
            var x = startX
            while x < rep.pixelsWide {
                seen += 1
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    let bright = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    if dark ? bright > 0.55 : bright < 0.45 { ink += 1 }
                }
                x += 1
            }
            y += 1
        }
        guard seen > 0 else { return 0 }
        return CGFloat(ink) / CGFloat(seen)
    }

    private static func modeFonts(in root: NSView?, word: String) -> [Int] {
        guard let root else { return [] }
        var weights: [Int] = []
        func walk(_ view: NSView) {
            if view.responds(to: Selector(("font"))), view.responds(to: Selector(("stringValue"))),
               let text = view.value(forKey: "stringValue") as? String, text == word,
               let font = view.value(forKey: "font") as? NSFont {
                weights.append(NSFontManager.shared.weight(of: font))
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return weights
    }

    private static func viewClasses(in root: NSView?) -> [String] {
        guard let root else { return [] }
        var names: [String] = []
        func walk(_ view: NSView) {
            if names.count < 40 { names.append(NSStringFromClass(type(of: view))) }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return names
    }

    private static func webGutterCount(_ web: WKWebView) -> Int {
        let script = "document.querySelectorAll('#xyz-gutter, #xyz-gutter .xyz-ln').length"
        var count = -1
        var done = false
        web.evaluateJavaScript(script) { value, _ in
            count = value as? Int ?? -1
            done = true
        }
        let start = Date()
        while !done, Date().timeIntervalSince(start) < 2 {
            pump(0.05)
        }
        return count
    }

    private static func menuHasLineNumberSetting() -> Bool {
        func walk(_ menu: NSMenu?) -> Bool {
            guard let menu else { return false }
            for item in menu.items {
                if item.identifier?.rawValue == "xyz.lineNumbers" { return true }
                let title = item.title.lowercased()
                if title.contains("line number") || title.contains("行号") { return true }
                if walk(item.submenu) { return true }
            }
            return false
        }
        return walk(NSApp.mainMenu)
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

#if os(macOS)
extension NSColor {
    func isClose(to other: NSColor, tolerance: Double = 0.02) -> Bool {
        guard let first = usingColorSpace(.deviceRGB), let second = other.usingColorSpace(.deviceRGB) else {
            return false
        }
        return abs(first.redComponent - second.redComponent) < tolerance
            && abs(first.greenComponent - second.greenComponent) < tolerance
            && abs(first.blueComponent - second.blueComponent) < tolerance
    }

    func isDifferent(from other: NSColor, tolerance: Double = 0.05) -> Bool {
        !isClose(to: other, tolerance: tolerance)
    }
}
#endif
