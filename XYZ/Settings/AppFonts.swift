import CoreText
import Foundation
import WebKit
import os

/// One bilingual family, registered only in this process. Font/spacing preferences
/// from older versions are deliberately not read; only size remains configurable.
enum AppFonts {
    static let prose = "Sarasa-Gothic-SC"
    static let code = "Sarasa-Mono-SC"
    static let scheme = "xyz-font"
    static let faces: [(file: String, postScript: String, family: String, weight: Int, style: String)] = [
        ("SarasaGothicSC-Regular", "\(prose)-Regular", "XYZ Prose", 400, "normal"),
        ("SarasaGothicSC-SemiBold", "\(prose)-SemiBold", "XYZ Prose", 600, "normal"),
        ("SarasaGothicSC-Italic", "\(prose)-Italic", "XYZ Prose", 400, "italic"),
        ("SarasaGothicSC-SemiBoldItalic", "\(prose)-SemiBold-Italic", "XYZ Prose", 600, "italic"),
        ("SarasaMonoSC-Regular", "\(code)-Regular", "XYZ Code", 400, "normal"),
        ("SarasaMonoSC-SemiBold", "\(code)-SemiBold", "XYZ Code", 600, "normal"),
    ]

    static func name(monospaced: Bool, emphasized: Bool = false) -> String {
        "\(monospaced ? code : prose)-\(emphasized ? "SemiBold" : "Regular")"
    }

    static func url(_ file: String) -> URL? {
        Bundle.main.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts")
    }

    static func register() { _ = registration }

    private static let registration: Void = {
        let logger = Logger(subsystem: "com.lizhichao.XYZ", category: "fonts")
        for face in faces {
            guard let url = url(face.file) else {
                logger.error("Missing bundled font: \(face.file, privacy: .public)")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
               let failure = error?.takeRetainedValue(),
               CFErrorGetCode(failure) != CTFontManagerError.alreadyRegistered.rawValue {
                logger.error("Font registration failed: \(String(describing: failure), privacy: .public)")
            }
        }
    }()

    /// Avoid embedding megabytes of CJK base64 into every note. WebKit loads only the
    /// faces used by the page through a read-only, exact-name bundle allowlist.
    static let webCSS = faces.map { face in
        """
        @font-face {
          font-family: '\(face.family)'; font-style: \(face.style); font-weight: \(face.weight);
          font-display: block;
          src: url('\(scheme)://bundled/\(face.file).ttf') format('truetype');
        }
        """
    }.joined(separator: "\n")

    static func resource(for request: URL) -> URL? {
        guard request.scheme == scheme, request.host == "bundled", request.query == nil,
              request.fragment == nil, request.user == nil, request.port == nil,
              let face = faces.first(where: { request.path == "/\($0.file).ttf" }) else { return nil }
        return url(face.file)
    }
}

final class BundledFontSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let request = urlSchemeTask.request.url,
              let resource = AppFonts.resource(for: request),
              let data = try? Data(contentsOf: resource, options: .mappedIfSafe),
              let response = HTTPURLResponse(url: request, statusCode: 200, httpVersion: nil,
                  headerFields: ["Content-Type": "font/ttf", "Access-Control-Allow-Origin": "*",
                                 "Content-Length": "\(data.count)"]) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    // Responses complete synchronously, so no queued callback can outlive cancellation.
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
