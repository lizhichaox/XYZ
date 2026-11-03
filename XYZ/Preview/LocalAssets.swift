import Foundation
import UniformTypeIdentifiers
import WebKit

/// Pictures and video next to a note.
///
/// Reading's page has a `<base>` in this scheme that points at the note's folder, so
/// `![](images/a.png)` asks for `xyz-asset://local/<folder>/images/a.png` and
/// ``LocalAssetSchemeHandler`` reads that file. Only image, audio, and video files are served.
/// The sandbox still decides what can be read: a folder window can show anything in its folder,
/// a single document only what the app has been given access to.
enum LocalAssets {
    static let scheme = "xyz-asset"

    static func baseHref(for directory: URL?) -> String {
        guard let directory else { return "" }
        var path = directory.standardizedFileURL.path
        if !path.hasSuffix("/") {
            path += "/"
        }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return scheme + "://local" + encoded
    }

    /// The file a page URL in this scheme names, without its fragment.
    static func fileURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func mediaType(of file: URL) -> UTType? {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return nil }
        guard type.conforms(to: .image) || type.conforms(to: .audiovisualContent) else { return nil }
        return type
    }
}

/// WebKit calls `start` and `stop` on the main thread. Files are read off it, and every answer
/// goes back to the main thread, where `active` lives.
final class LocalAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = LocalAssetSchemeHandler()

    /// Tasks WebKit has not stopped. Answering a stopped task raises an exception.
    private var active = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let file = LocalAssets.fileURL(for: requestURL),
              let type = LocalAssets.mediaType(of: file) else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        active.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: file, options: .mappedIfSafe)
            DispatchQueue.main.async {
                guard self.active.remove(id) != nil else { return }
                guard let data else {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let response = URLResponse(
                    url: requestURL,
                    mimeType: type.preferredMIMEType ?? "application/octet-stream",
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask))
    }
}
