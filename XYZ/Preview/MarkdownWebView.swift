import os
import SwiftUI
import WebKit
import XYZCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PreviewLog {
    static let logger = Logger(subsystem: "com.lizhichao.XYZ", category: "preview")
}

/// One web view for one open note. SwiftUI may rebuild the representable; this object stays.
final class PreviewWebHost {
    private var storage: WKWebView?
    private var coordinatorStorage: PreviewWebCoordinator?

    var webView: WKWebView {
        if let storage { return storage }
        let created = PreviewWebViewFactory.make()
        let coordinator = PreviewWebCoordinator()
        created.navigationDelegate = coordinator
        storage = created
        coordinatorStorage = coordinator
        PreviewLog.logger.notice("webview created")
        return created
    }

    var coordinator: PreviewWebCoordinator {
        _ = webView
        return coordinatorStorage!
    }
}

struct MarkdownWebView: View {
    var html: String
    var host: PreviewWebHost
    var scrollLink: EditorScrollLink
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        #if os(macOS)
        MacMarkdownWebView(html: html, theme: colorScheme == .dark ? "dark" : "light", host: host, scrollLink: scrollLink)
        #else
        IOSMarkdownWebView(html: html, theme: colorScheme == .dark ? "dark" : "light", host: host, scrollLink: scrollLink)
        #endif
    }
}

#if os(macOS)
private struct MacMarkdownWebView: NSViewRepresentable {
    var html: String
    var theme: String
    var host: PreviewWebHost
    var scrollLink: EditorScrollLink

    func makeNSView(context: Context) -> ReadingSurface {
        let surface = ReadingSurface()
        if let webView = claim(host.webView) as? XYZPreviewWebView {
            surface.install(webView)
            host.coordinator.update(webView: webView, html: html, theme: theme, scrollLink: scrollLink)
        }
        return surface
    }

    func updateNSView(_ surface: ReadingSurface, context: Context) {
        guard let webView = host.webView as? XYZPreviewWebView else { return }
        surface.install(webView)
        host.coordinator.update(webView: webView, html: html, theme: theme, scrollLink: scrollLink)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadingSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 480)
    }

    func makeCoordinator() -> PreviewWebCoordinator {
        host.coordinator
    }
}

/// ⌘F in Reading. The field is the system search field; WebKit moves the highlight.
final class XYZPreviewWebView: WKWebView {
    weak var surface: ReadingSurface?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditorCommands.shared.handleKeyEquivalent(event) {
            return true
        }
        if let action = ReadingFindKeys.action(for: event) {
            surface?.perform(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Edit → Find. `performTextFinderAction` is on `NSResponder` (macOS 10.7).
    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        guard let action = NSTextFinder.Action(rawValue: tag) else {
            super.performTextFinderAction(sender)
            return
        }
        switch action {
        case .showFindInterface, .nextMatch, .previousMatch:
            surface?.perform(action)
        default:
            super.performTextFinderAction(sender)
        }
    }
}

private enum ReadingFindKeys {
    static func action(for event: NSEvent) -> NSTextFinder.Action? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, key == "f" { return .showFindInterface }
        if flags == .command, key == "g" { return .nextMatch }
        if flags == [.command, .shift], key == "g" { return .previousMatch }
        return nil
    }
}

final class ReadingSurface: NSView, NSSearchFieldDelegate {
    private let findHost = NSView()
    private let findField = NSSearchField()
    private var webView: XYZPreviewWebView?
    private var collapsed: NSLayoutConstraint?
    private var fieldTop: NSLayoutConstraint!
    private var fieldBottom: NSLayoutConstraint!
    private var backwards = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        findHost.translatesAutoresizingMaskIntoConstraints = false
        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Find"
        findField.focusRingType = .none
        findField.controlSize = .regular
        findField.delegate = self
        findField.setAccessibilityLabel("Find in note")
        findField.setContentHuggingPriority(.required, for: .vertical)
        findField.setContentCompressionResistancePriority(.required, for: .vertical)
        findHost.setContentCompressionResistancePriority(.required, for: .vertical)
        findHost.addSubview(findField)
        addSubview(findHost)
        let collapsed = findHost.heightAnchor.constraint(equalToConstant: 0)
        self.collapsed = collapsed
        fieldTop = findField.topAnchor.constraint(equalTo: findHost.topAnchor, constant: 8)
        fieldBottom = findField.bottomAnchor.constraint(equalTo: findHost.bottomAnchor, constant: -8)
        fieldTop.priority = NSLayoutConstraint.Priority(rawValue: 750)
        fieldBottom.priority = NSLayoutConstraint.Priority(rawValue: 750)
        NSLayoutConstraint.activate([
            findHost.topAnchor.constraint(equalTo: topAnchor),
            findHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            findHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            collapsed,
            fieldTop,
            fieldBottom,
            findField.leadingAnchor.constraint(equalTo: findHost.leadingAnchor, constant: 12),
            findField.trailingAnchor.constraint(equalTo: findHost.trailingAnchor, constant: -12),
        ])
        findHost.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func install(_ webView: XYZPreviewWebView) {
        webView.surface = self
        guard self.webView !== webView || webView.superview !== self else { return }
        self.webView?.removeFromSuperview()
        self.webView = webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: findHost.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditorCommands.shared.handleKeyEquivalent(event) {
            return true
        }
        if let action = ReadingFindKeys.action(for: event) {
            perform(action)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func perform(_ action: NSTextFinder.Action) {
        if action == .previousMatch {
            backwards = true
            reveal(run: true, fromStart: false)
        } else if action == .nextMatch {
            backwards = false
            reveal(run: true, fromStart: false)
        } else if action == .showFindInterface {
            backwards = false
            reveal(run: !findField.stringValue.isEmpty, fromStart: true)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        backwards = false
        runFind(fromStart: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hideFind()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            backwards = false
            runFind(fromStart: false)
            return true
        }
        return false
    }

    private func reveal(run: Bool, fromStart: Bool) {
        setFindVisible(true)
        window?.makeFirstResponder(findField)
        let length = (findField.stringValue as NSString).length
        findField.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
        if run { runFind(fromStart: fromStart) }
    }

    private func hideFind() {
        setFindVisible(false)
        window?.makeFirstResponder(webView)
    }

    private func setFindVisible(_ visible: Bool) {
        findHost.isHidden = !visible
        collapsed?.isActive = !visible
        let priority: NSLayoutConstraint.Priority = visible ? .required : NSLayoutConstraint.Priority(rawValue: 750)
        fieldTop.priority = priority
        fieldBottom.priority = priority
    }

    /// `WKWebView.find(_:configuration:completionHandler:)` is public on macOS 11.
    /// A changed query starts at the top of the note; next and previous keep the current match.
    private func runFind(fromStart: Bool) {
        let query = findField.stringValue
        guard !query.isEmpty, let webView else { return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        let restart = fromStart && !backwards
        backwards = false
        if restart {
            webView.evaluateJavaScript(Self.rewindScript) { _, _ in
                DispatchQueue.main.async {
                    webView.find(query, configuration: configuration) { _ in }
                }
            }
        } else {
            webView.find(query, configuration: configuration) { _ in }
        }
    }

    private static let rewindScript = """
    (function(){
      var selection = window.getSelection();
      if (selection) selection.removeAllRanges();
      var body = document.body;
      if (!body || !selection) return;
      var range = document.createRange();
      range.setStart(body, 0);
      range.collapse(true);
      selection.addRange(range);
    })()
    """
}
#else
private struct IOSMarkdownWebView: UIViewRepresentable {
    var html: String
    var theme: String
    var host: PreviewWebHost
    var scrollLink: EditorScrollLink

    func makeUIView(context: Context) -> WKWebView {
        let webView = claim(host.webView)
        host.coordinator.update(webView: webView, html: html, theme: theme, scrollLink: scrollLink)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        host.coordinator.update(webView: webView, html: html, theme: theme, scrollLink: scrollLink)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 480)
    }

    func makeCoordinator() -> PreviewWebCoordinator {
        host.coordinator
    }
}
#endif

private func claim(_ webView: WKWebView) -> WKWebView {
    if webView.superview != nil {
        webView.removeFromSuperview()
    }
    return webView
}

private enum PreviewWebViewFactory {
    static func make() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        #if os(macOS)
        let webView = XYZPreviewWebView(frame: .zero, configuration: configuration)
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = true
        #if os(macOS)
        webView.setAccessibilityLabel("Markdown preview")
        #endif
        PreviewWebChrome.apply(to: webView)
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }
}

final class PreviewWebCoordinator: NSObject, WKNavigationDelegate {
    private let css = PreviewStyles.load()
    private var didStartLoad = false
    private var isReady = false
    private var pendingHTML: String?
    private var appliedHTML: String?
    private var pendingTheme: String?
    private var appliedTheme: String?
    private var didLogScriptFailure = false
    private var scrollLink: EditorScrollLink?

    func update(webView: WKWebView, html: String, theme: String, scrollLink: EditorScrollLink) {
        pendingHTML = html
        pendingTheme = theme
        self.scrollLink = scrollLink
        scrollLink.capture = { PreviewWebChrome.anchor(in: webView) }
        PreviewWebChrome.apply(to: webView)
        if !didStartLoad {
            loadShell(webView, html: html, theme: theme)
            return
        }
        guard isReady else { return }
        push(to: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        PreviewWebChrome.apply(to: webView)
        PreviewLog.logger.notice("navigation finished")
        push(to: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logNavigationFailure("navigation failed", error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        logNavigationFailure("provisional navigation failed", error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        PreviewLog.logger.error("web content process terminated")
        isReady = false
        didStartLoad = false
        appliedHTML = nil
        appliedTheme = nil
        didLogScriptFailure = false
        loadShell(webView, html: pendingHTML ?? "", theme: pendingTheme ?? "light")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url {
                Self.openIfSafe(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func loadShell(_ webView: WKWebView, html: String, theme: String) {
        didStartLoad = true
        isReady = false
        appliedHTML = html
        appliedTheme = theme
        PreviewLog.logger.notice("shell requested")
        webView.loadHTMLString(PreviewPage.shell(css: css, html: html, theme: theme), baseURL: nil)
    }

    private func push(to webView: WKWebView) {
        guard isReady else { return }
        var script = ""
        if let theme = pendingTheme, theme != appliedTheme {
            appliedTheme = theme
            script += "setTheme(\(PreviewPage.javaScriptLiteral(theme)));"
        }
        if let html = pendingHTML, html != appliedHTML {
            appliedHTML = html
            script += "setContent(\(PreviewPage.javaScriptLiteral(html)));"
        }
        if let anchor = scrollLink?.take(for: .reading) {
            let fraction = min(1, max(0, anchor.fraction))
            script += "xyzReveal(\(fraction), \(PreviewPage.javaScriptLiteral(anchor.probe)));"
        }
        guard !script.isEmpty else { return }
        evaluate(webView, script)
    }

    private func evaluate(_ webView: WKWebView, _ script: String) {
        webView.evaluateJavaScript(script) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard !self.didLogScriptFailure else { return }
                self.didLogScriptFailure = true
                PreviewLog.logger.error("script failed")
            }
        }
    }

    private func logNavigationFailure(_ event: String, _ error: Error) {
        let nsError = error as NSError
        let eventName = event
        let domain = nsError.domain
        let code = nsError.code
        PreviewLog.logger.error("\(eventName, privacy: .public) domain=\(domain, privacy: .public) code=\(code, privacy: .public)")
    }

    private static func openIfSafe(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        switch scheme {
        case "http", "https", "mailto":
            break
        default:
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

private enum PreviewWebChrome {
    static func apply(to webView: WKWebView) {
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        silence(webView)
        #else
        let color = UIColor.systemBackground
        webView.isOpaque = true
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        #endif
    }

    static func anchor(in webView: WKWebView) -> EditorScrollAnchor {
        #if os(macOS)
        guard let scroll = scrollView(in: webView), let document = scroll.documentView else {
            return EditorScrollAnchor(fraction: 0, probe: "")
        }
        let span = max(document.frame.height - scroll.contentView.bounds.height, 1)
        let fraction = min(1, max(0, Double(scroll.contentView.bounds.origin.y / span)))
        return EditorScrollAnchor(fraction: fraction, probe: "")
        #else
        let scroll = webView.scrollView
        let span = max(scroll.contentSize.height - scroll.bounds.height, 1)
        let fraction = min(1, max(0, Double(scroll.contentOffset.y / span)))
        return EditorScrollAnchor(fraction: fraction, probe: "")
        #endif
    }

    #if os(macOS)
    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }
    #endif

    static func canvasCSS() -> String {
        let light = hex(dark: false)
        let dark = hex(dark: true)
        return """
        :root { --canvas: \(light); }
        :root[data-theme="dark"] { --canvas: \(dark); }
        @media (prefers-color-scheme: dark) {
          :root:not([data-theme="light"]) { --canvas: \(dark); }
        }
        """
    }

    #if os(macOS)
    private static func silence(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
            scroll.drawsBackground = true
            scroll.backgroundColor = .textBackgroundColor
            scroll.contentView.drawsBackground = true
            scroll.contentView.backgroundColor = .textBackgroundColor
        }
        for child in view.subviews {
            silence(child)
        }
    }

    private static func hex(dark: Bool) -> String {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var color = NSColor.textBackgroundColor
        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? color
            }
        }
        return hex(color, fallback: dark ? "#1e1e1e" : "#ffffff")
    }

    private static func hex(_ color: NSColor, fallback: String) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return fallback }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
    #else
    private static func hex(dark: Bool) -> String {
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        let color = UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return dark ? "#000000" : "#ffffff"
        }
        return String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    #endif
}

private enum PreviewStyles {
    static func load() -> String {
        if let url = Bundle.main.url(forResource: "Preview", withExtension: "css"),
           let css = try? String(contentsOf: url, encoding: .utf8),
           !css.isEmpty {
            return css
        }
        return "html, body { margin: 0; min-height: 100%; background-color: #fff; overscroll-behavior: none; } body { font: 16px -apple-system, sans-serif; padding: 20px; }"
    }
}

private enum PreviewPage {
    static func shell(css: String, html: String, theme: String) -> String {
        let themeName = theme == "dark" ? "dark" : "light"
        return """
        <!DOCTYPE html>
        <html data-theme="\(themeName)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        \(css)
        \(PreviewWebChrome.canvasCSS())
        </style>
        </head>
        <body>
        <article id="content">\(html)</article>
        <script>
        function setContent(html) {
          var node = document.getElementById("content");
          if (node) node.innerHTML = html;
        }
        function setTheme(theme) {
          document.documentElement.setAttribute("data-theme", theme);
        }
        function xyzReveal(fraction, probe) {
          var nodes = document.querySelectorAll("h1,h2,h3,h4,h5,h6,p,li,pre");
          var max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
          var target = max * fraction;
          if (probe) {
            var best = null;
            var bestDistance = 1e15;
            for (var i = 0; i < nodes.length; i++) {
              var text = (nodes[i].innerText || "").replace(/^\\s+|\\s+$/g, "");
              if (!text || text.indexOf(probe) === -1) continue;
              var top = nodes[i].getBoundingClientRect().top + window.scrollY;
              var distance = Math.abs(top - target);
              if (distance < bestDistance) {
                best = nodes[i];
                bestDistance = distance;
              }
            }
            if (best) {
              best.scrollIntoView({block: "start"});
              return;
            }
          }
          window.scrollTo(0, target);
        }
        setTheme("\(themeName)");
        </script>
        </body>
        </html>
        """
    }

    static func javaScriptLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              var text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        if text.hasPrefix("["), text.hasSuffix("]") {
            text.removeFirst()
            text.removeLast()
        }
        return text
    }
}
