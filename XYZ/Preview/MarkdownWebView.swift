import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MarkdownWebView: View {
    var html: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        #if os(macOS)
        MacMarkdownWebView(html: html, theme: colorScheme == .dark ? "dark" : "light")
        #else
        IOSMarkdownWebView(html: html, theme: colorScheme == .dark ? "dark" : "light")
        #endif
    }
}

#if os(macOS)
private struct MacMarkdownWebView: NSViewRepresentable {
    var html: String
    var theme: String

    func makeNSView(context: Context) -> WKWebView {
        let webView = PreviewWebViewFactory.make()
        webView.navigationDelegate = context.coordinator
        context.coordinator.update(webView: webView, html: html, theme: theme)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(webView: webView, html: html, theme: theme)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 480)
    }

    func makeCoordinator() -> PreviewWebCoordinator {
        PreviewWebCoordinator()
    }
}
#else
private struct IOSMarkdownWebView: UIViewRepresentable {
    var html: String
    var theme: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = PreviewWebViewFactory.make()
        webView.navigationDelegate = context.coordinator
        context.coordinator.update(webView: webView, html: html, theme: theme)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(webView: webView, html: html, theme: theme)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 640, height: proposal.height ?? 480)
    }

    func makeCoordinator() -> PreviewWebCoordinator {
        PreviewWebCoordinator()
    }
}
#endif

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

private final class PreviewWebCoordinator: NSObject, WKNavigationDelegate {
    private let css = PreviewStyles.load()
    private var didStartLoad = false
    private var isReady = false
    private var pendingHTML: String?
    private var appliedHTML: String?
    private var pendingTheme: String?
    private var appliedTheme: String?
    private var reloadFallbackHTML: String?

    func update(webView: WKWebView, html: String, theme: String) {
        pendingHTML = html
        pendingTheme = theme
        #if os(macOS)
        webView.underPageBackgroundColor = .textBackgroundColor
        #endif
        if !didStartLoad {
            didStartLoad = true
            appliedHTML = html
            appliedTheme = theme
            webView.loadHTMLString(PreviewPage.shell(css: css, html: html, theme: theme), baseURL: nil)
            return
        }
        guard isReady else { return }
        push(to: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        push(to: webView)
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

    private func push(to webView: WKWebView) {
        guard isReady else { return }
        if let theme = pendingTheme, theme != appliedTheme {
            appliedTheme = theme
            evaluate(webView, "setTheme(\(PreviewPage.javaScriptLiteral(theme)))", fallback: nil)
        }
        if let html = pendingHTML, html != appliedHTML {
            appliedHTML = html
            evaluate(webView, "setContent(\(PreviewPage.javaScriptLiteral(html)))", fallback: html)
        }
    }

    private func evaluate(_ webView: WKWebView, _ script: String, fallback: String?) {
        webView.evaluateJavaScript(script) { _, error in
            guard error != nil, let fallback, self.reloadFallbackHTML != fallback else { return }
            self.reloadFallbackHTML = fallback
            let theme = self.appliedTheme ?? "light"
            self.isReady = false
            webView.loadHTMLString(PreviewPage.shell(css: self.css, html: fallback, theme: theme), baseURL: nil)
        }
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
