import Foundation

/// Plain-text contents of a document, independent of SwiftUI's document scene.
///
/// Files are read and written as UTF-8. A leading UTF-8 byte order mark is removed on read
/// and is not written back, so a save does not churn the BOM. Newlines are preserved as they
/// appear in the string (LF or CRLF).
public struct TextDocument: Equatable, Sendable {
    public var text: String

    public init(text: String = "") {
        self.text = text
    }

    public init(data: Data) throws {
        self.text = try Self.decode(data)
    }

    public func data() -> Data {
        Data(text.utf8)
    }

    public enum DecodingError: Error, Equatable {
        case invalidUTF8
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    private static func decode(_ data: Data) throws -> String {
        var bytes = data
        if bytes.starts(with: utf8BOM) {
            bytes.removeFirst(utf8BOM.count)
        }
        guard var text = String(data: bytes, encoding: .utf8) else {
            throw DecodingError.invalidUTF8
        }
        if text.first == "\u{FEFF}" {
            text.removeFirst()
        }
        return text
    }
}
