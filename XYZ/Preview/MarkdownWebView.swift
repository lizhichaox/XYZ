import os
import SwiftUI
import WebKit

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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        #if os(macOS)
        MacMarkdownWebView(html: html, theme: colorScheme == .dark ? "dark" : "light", host: host)
        #else
        IOSMarkdownWebView(html: html, theme: colorScheme == .dark ? "dark" : "light", host: host)
        #endif
    }
}

#if os(macOS)
private struct MacMarkdownWebView: NSViewRepresentable {
    var html: String
    var theme: String
    var host: PreviewWebHost

    func makeNSView(context: Context) -> WKWebView {
        let webView = claim(host.webView)
        host.coordinator.update(webView: webView, html: html, theme: theme)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        host.coordinator.update(webView: webView, html: html, theme: theme)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 480)
    }

    func makeCoordinator() -> PreviewWebCoordinator {
        host.coordinator
    }
}
#else
private struct IOSMarkdownWebView: UIViewRepresentable {
    var html: String
    var theme: String
    var host: PreviewWebHost

    func makeUIView(context: Context) -> WKWebView {
        let webView = claim(host.webView)
        host.coordinator.update(webView: webView, html: html, theme: theme)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        host.coordinator.update(webView: webView, html: html, theme: theme)
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
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = true
        #if os(macOS)
        // AppKit's isOpaque is read-only. Match the editor page color, including overscroll.
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.setAccessibilityLabel("Markdown preview")
        #else
        webView.isOpaque = true
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        #endif
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

    func update(webView: WKWebView, html: String, theme: String) {
        pendingHTML = html
        pendingTheme = theme
        #if os(macOS)
        webView.underPageBackgroundColor = .textBackgroundColor
        #endif
        if !didStartLoad {
            loadShell(webView, html: html, theme: theme)
            return
        }
        guard isReady else { return }
        push(to: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
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
        if let theme = pendingTheme, theme != appliedTheme {
            appliedTheme = theme
            evaluate(webView, "setTheme(\(PreviewPage.javaScriptLiteral(theme)))")
        }
        if let html = pendingHTML, html != appliedHTML {
            appliedHTML = html
            evaluate(webView, "setContent(\(PreviewPage.javaScriptLiteral(html)))")
        }
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

private enum PreviewStyles {
    static func load() -> String {
        if let url = Bundle.main.url(forResource: "Preview", withExtension: "css"),
           let css = try? String(contentsOf: url, encoding: .utf8),
           !css.isEmpty {
            return css
        }
        return "body { font: 16px -apple-system, sans-serif; margin: 0; padding: 20px; }"
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
