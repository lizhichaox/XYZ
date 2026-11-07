import Foundation

/// Plain-text contents of a document, independent of SwiftUI's document scene.
///
/// The bytes keep the encoding they were read with: UTF-8, UTF-8 with a byte-order
/// mark, UTF-16 with or without one, or Windows-1252. Line endings are left as they
/// appear in the string, so a save writes the same bytes back. New documents are UTF-8
/// and get no byte-order mark.
public struct TextDocument: Equatable, Sendable {
    public var text: String
    /// The encoding to use on the next save. A document read from disk keeps the one
    /// it had; text that encoding cannot hold falls back to UTF-8 in `data()`.
    public let encoding: TextEncoding

    public init(text: String = "", encoding: TextEncoding = .utf8) {
        self.text = text
        self.encoding = encoding
    }

    public init(data: Data) throws {
        guard let decoded = TextBytes.decodeKeepingEndings(data, allowLegacy: true) else {
            throw DecodingError.unreadableBytes
        }
        self.text = decoded.text
        self.encoding = decoded.encoding
    }

    public func data() -> Data {
        if let data = TextBytes.encode(text, encoding: encoding, lineEnding: .lf) {
            return data
        }
        // A character was typed that the file's encoding cannot store (Chinese in a
        // Windows-1252 note). Writing UTF-8 keeps the text instead of dropping the file.
        return Data(text.utf8)
    }

    public enum DecodingError: Error, Equatable {
        /// The bytes are not text in any encoding the app reads.
        case unreadableBytes
    }
}
