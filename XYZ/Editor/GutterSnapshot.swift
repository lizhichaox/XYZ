#if os(macOS)
import AppKit
import SwiftUI
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
        stage(production == nil ? "search" : "production-failed")
        let failure = rendered ?? wrapped ?? reading ?? aligned ?? production ?? SearchTypingCheck.run() ?? EscapeCrashCheck.run() ?? SidebarColumnFitCheck.run()
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
        if let failure = renderProductionEditor(wraps: true) { return failure }
        if let failure = renderProductionEditor(wraps: false) { return failure }
        return nil
    }

    @MainActor
    private static func productionEditor(text: String, wraps: Bool, lineNumbers: Bool) -> XYZMacEditor {
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
            onTextChange: { _ in }
        )
    }

    private static func renderProductionEditor(wraps: Bool) -> String? {
        let text = "one\n" + String(repeating: "wrap ", count: 24) + "\n\nfour\n"
        print("GUTTER_PROD stage=host wrap=\(wraps ? 1 : 0)")
        fflush(stdout)
        let editor = MainActor.assumeIsolated {
            productionEditor(text: text, wraps: wraps, lineNumbers: true)
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
        window.contentView = host
        if let failure = checkProduction(host: host, window: window, wraps: wraps, label: "load") {
            return failure
        }
        let hidden = MainActor.assumeIsolated {
            productionEditor(text: text, wraps: wraps, lineNumbers: false)
        }
        host.rootView = hidden
        if let failure = checkProductionHidden(host: host, window: window, wraps: wraps) {
            return failure
        }
        let shown = MainActor.assumeIsolated {
            productionEditor(text: text, wraps: wraps, lineNumbers: true)
        }
        host.rootView = shown
        return checkProduction(host: host, window: window, wraps: wraps, label: "toggle")
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
        wraps: Bool
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
        return nil
    }

    private static func checkProduction(
        host: NSHostingView<XYZMacEditor>,
        window: NSWindow,
        wraps: Bool,
        label: String
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
        let background = NSColor.xyzEditor
        var plate = background
        let appearance = window.appearance ?? NSAppearance(named: .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            plate = background.usingColorSpace(.deviceRGB) ?? background
        }
        let ink = nonBackgroundPixels(in: rep, rect: sample, background: plate)
        if ink < 30 {
            let snapshot = gutter.testingSnapshot()
            return "production wrap=\(wraps ? 1 : 0) label=\(label): gutter painted \(ink) contrasting pixels api=\(snapshot.api) evidence=missing"
        }
        let snapshot = gutter.testingSnapshot()
        let numbered = snapshot.rows.filter(\.shows).map(\.line)
        print("GUTTER_PROD_LABELS wrap=\(wraps ? 1 : 0) label=\(label) api=\(snapshot.api) numbered=\(numbered) visual=\(snapshot.rows.count)")
        fflush(stdout)
        if numbered.first != 1 {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): numbered \(numbered) api=\(snapshot.api)"
        }
        if numbered != Array(1...numbered.count) {
            return "production wrap=\(wraps ? 1 : 0) label=\(label): numbered \(numbered) is not a source prefix"
        }
        if wraps && snapshot.rows.count <= numbered.count {
            return "production wrap=1 label=\(label): long line did not wrap visual=\(snapshot.rows.count)"
        }
        return nil
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
        xyzLayoutGutter();
        Array.from(document.querySelectorAll('#xyz-gutter .xyz-ln')).map(function(node) {
          return node.getAttribute('data-source-line') + ':' + Math.round(parseFloat(node.style.top) || 0);
        }).join(',');
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
        print("GUTTER_READING pairs=\(output) sourceLines=\(sourceLines)")
        fflush(stdout)
        if output.hasPrefix("error") { return "reading: \(output)" }
        let labels = output.split(separator: ",").compactMap { piece -> (Int, Int)? in
            let parts = piece.split(separator: ":")
            guard parts.count == 2, let line = Int(parts[0]), let y = Int(parts[1]) else { return nil }
            return (line, y)
        }
        if labels.isEmpty { return "reading: no labels evidence=missing output=\(output)" }
        var previousY = Int.min
        for label in labels {
            if label.0 < 1 || label.0 > sourceLines {
                return "reading: line \(label.0) is not a source line (1...\(sourceLines))"
            }
            if label.1 <= previousY {
                return "reading: y does not increase \(labels)"
            }
            previousY = label.1
        }
        let lines = labels.map(\.0)
        if !lines.contains(1) { return "reading: missing the heading source line 1 in \(lines)" }
        if lines.count > sourceLines { return "reading: more labels than source lines \(lines)" }
        return nil
    }

    /// The number's center sits on the first text row, including a large heading and a wrapped paragraph.
    private static func renderReadingAlignment() -> String? {
        let heading = "标题 Heading wraps onto a second visual row in this narrow column"
        let paragraph = "段落 " + String(repeating: "paragraph body ", count: 18)
        let markdown = "# \(heading)\n\n\(paragraph)\n\n- alpha item\n- 第二项\n"
        let html = MarkdownHTML.render(markdown)
        let sourceLines = LineIndex(markdown).count
        let page = PreviewPage.shell(css: PreviewStyles.load(), html: html, theme: "light", prefs: PreviewPrefs(lineNumbers: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 280, height: 720))
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
        guard waiter.wait(seconds: 8) else { return "reading-align: web view did not finish loading" }
        let script = """
        function xyzInk(value) {
          for (var i = 0; i < value.length; i++) {
            var code = value.charCodeAt(i);
            if (code !== 32 && code !== 9 && code !== 10 && code !== 13) return true;
          }
          return false;
        }
        function xyzRow(element) {
          var block = element.getBoundingClientRect();
          var walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, null);
          var text = null;
          while (walker.nextNode()) {
            if (xyzInk(walker.currentNode.nodeValue || "")) { text = walker.currentNode; break; }
          }
          var top = block.top;
          var height = block.height;
          if (text) {
            var range = document.createRange();
            range.selectNodeContents(text);
            var rects = range.getClientRects();
            for (var r = 0; r < rects.length; r++) {
              if (rects[r].height >= 1 && rects[r].width >= 1) {
                top = rects[r].top;
                height = rects[r].height;
                break;
              }
            }
          }
          return {top: top, height: height, blockTop: block.top, blockHeight: block.height};
        }
        function xyzLeaf(line) {
          var all = document.querySelectorAll("[data-line]");
          for (var i = 0; i < all.length; i++) {
            if ((parseInt(all[i].getAttribute("data-line"), 10) || 0) !== line) continue;
            if (all[i].querySelector("[data-line]")) continue;
            return all[i];
          }
          return null;
        }
        function xyzCollect(size) {
          setPrefs(size, false, 1.7, "", "", "");
          xyzLayoutGutter();
          var labels = document.querySelectorAll("#xyz-gutter .xyz-ln");
          var parts = [];
          for (var i = 0; i < labels.length; i++) {
            var label = labels[i];
            var line = parseInt(label.getAttribute("data-source-line"), 10) || 0;
            var leaf = xyzLeaf(line);
            if (!leaf) { parts.push(line + ":missing:0:0:0:0:0:0"); continue; }
            var row = xyzRow(leaf);
            var box = label.getBoundingClientRect();
            var mid = box.top + box.height / 2;
            var rowMid = row.top + row.height / 2;
            var blockMid = row.blockTop + row.blockHeight / 2;
            parts.push([
              line,
              leaf.tagName.toLowerCase(),
              Math.round(mid - rowMid),
              Math.round(row.height),
              Math.round(row.blockHeight),
              Math.round(box.top - row.blockTop),
              Math.round(mid - blockMid),
              Math.round(box.right)
            ].join(":"));
          }
          return parts.join(",");
        }
        xyzCollect(16) + "||" + xyzCollect(22);
        """
        guard let output = evaluate(web, script), !output.hasPrefix("error") else {
            return "reading-align: \(output ?? "script did not return")"
        }
        print("GUTTER_READING_ALIGN \(output)")
        fflush(stdout)
        let chunks = output.components(separatedBy: "||")
        if chunks.count != 2 {
            return "reading-align: expected two font sizes, got \(output)"
        }
        for (index, chunk) in chunks.enumerated() {
            let size = index == 0 ? 16 : 22
            if let failure = checkReadingAlignment(chunk, size: size, sourceLines: sourceLines) {
                return failure
            }
        }
        return nil
    }

    private static func checkReadingAlignment(_ chunk: String, size: Int, sourceLines: Int) -> String? {
        let rows = chunk.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        if rows.isEmpty { return "reading-align size=\(size): no labels evidence=missing" }
        var sawHeading = false
        var sawWrapped = false
        var rights: [Int] = []
        var lines: [Int] = []
        for row in rows {
            let parts = row.split(separator: ":").map(String.init)
            guard parts.count == 8,
                  let line = Int(parts[0]),
                  let delta = Int(parts[2]),
                  let rowH = Int(parts[3]),
                  let blockH = Int(parts[4]),
                  let drop = Int(parts[5]),
                  let blockDelta = Int(parts[6]),
                  let right = Int(parts[7]) else {
                return "reading-align size=\(size): bad row \(row)"
            }
            let tag = parts[1]
            if line < 1 || line > sourceLines {
                return "reading-align size=\(size): line \(line) is not a source line"
            }
            if lines.contains(line) {
                return "reading-align size=\(size): line \(line) is numbered twice"
            }
            lines.append(line)
            if abs(delta) > 3 {
                return "reading-align size=\(size): \(tag) line \(line) center is \(delta)px off the first text row"
            }
            rights.append(right)
            if tag == "h1", rowH >= 24, drop >= 4 {
                sawHeading = true
            }
            if blockH >= rowH + rowH / 2, abs(blockDelta) > abs(delta) + rowH / 3 {
                sawWrapped = true
            }
        }
        if !sawHeading {
            return "reading-align size=\(size): heading number is still on the block top \(rows)"
        }
        if !sawWrapped {
            return "reading-align size=\(size): no wrapped block kept its number on the first row \(rows)"
        }
        if let first = rights.first, rights.contains(where: { abs($0 - first) > 1 }) {
            return "reading-align size=\(size): gutter right edges differ \(rights)"
        }
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
