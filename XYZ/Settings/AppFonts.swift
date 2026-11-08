import CoreText
import Foundation
import os

/// Bundled, process-scoped fonts. Never installs anything into the user's Font Book.
/// WebKit is a separate process: its faces are embedded from the same pinned release.
enum AppFonts {
    static let faces: [(name: String, weight: Int, style: String)] = [
        ("Regular", 400, "normal"), ("Medium", 500, "normal"),
        ("SemiBold", 600, "normal"), ("Bold", 700, "normal"),
        ("Italic", 400, "italic"), ("BoldItalic", 700, "italic"),
    ]

    static func url(_ face: String, extension ext: String) -> URL? {
        Bundle.main.url(forResource: "JetBrainsMono-\(face)", withExtension: ext, subdirectory: "Fonts")
    }

    static func register() {
        _ = registration
    }

    private static let registration: Void = {
        let logger = Logger(subsystem: "com.lizhichao.XYZ", category: "fonts")
        for face in faces {
            guard let url = url(face.name, extension: "ttf") else {
                logger.error("Missing bundled font: \(face.name, privacy: .public)")
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

    /// Data URLs keep Reading offline and independent of both installed fonts and
    /// the note's security-scoped asset root. Generated once, not on every keystroke.
    static let webCSS: String = faces.compactMap { face -> String? in
        guard let url = url(face.name, extension: "woff2"), let data = try? Data(contentsOf: url) else { return nil }
        return """
        @font-face {
          font-family: 'XYZ JetBrains Mono';
          font-style: \(face.style);
          font-weight: \(face.weight);
          src: url(data:font/woff2;base64,\(data.base64EncodedString())) format('woff2');
        }
        """
    }.joined(separator: "\n")
}
