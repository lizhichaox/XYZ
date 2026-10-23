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
        // AppKit's isOpaque is read-only. A clear page background is what makes the preview transparent.
        webView.underPageBackgroundColor = .clear
        webView.setAccessibilityLabel("Markdown preview")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isOpaque = false
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }
}

private final class PreviewWebCoordinator: NSObject, WKNavigationDelegate {
    private let shellHTML = PreviewPage.shell(css: PreviewStyles.load())
    private var didStartLoad = false
    private var isReady = false
    private var pendingHTML: String?
    private var appliedHTML: String?
    private var pendingTheme: String?
    private var appliedTheme: String?

    func update(webView: WKWebView, html: String, theme: String) {
        pendingHTML = html
        pendingTheme = theme
        if !didStartLoad {
            didStartLoad = true
            webView.loadHTMLString(shellHTML, baseURL: nil)
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
            webView.callAsyncJavaScript(
                "setTheme(theme)",
                arguments: ["theme": theme],
                in: nil,
                in: .page
            ) { _ in }
        }
        if let html = pendingHTML, html != appliedHTML {
            appliedHTML = html
            webView.callAsyncJavaScript(
                "setContent(html)",
                arguments: ["html": html],
                in: nil,
                in: .page
            ) { _ in }
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
    static func shell(css: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        \(css)
        </style>
        </head>
        <body>
        <article id="content"></article>
        <script>
        function setContent(html) {
          var node = document.getElementById("content");
          if (node) node.innerHTML = html;
        }
        function setTheme(theme) {
          document.documentElement.setAttribute("data-theme", theme);
        }
        (function () {
          var dark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
          setTheme(dark ? "dark" : "light");
        })();
        </script>
        </body>
        </html>
        """
    }
}
