import Foundation

/// How the bytes of a text file are encoded.
///
/// The editor works in Unicode. A save writes this encoding back, including a byte-order mark
/// when the file had one.
public enum TextEncoding: String, Equatable, Sendable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16LEBOM
    case utf16BE
    case utf16BEBOM
    case windows1252

    public var label: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 with BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16LEBOM: return "UTF-16 LE with BOM"
        case .utf16BE: return "UTF-16 BE"
        case .utf16BEBOM: return "UTF-16 BE with BOM"
        case .windows1252: return "Windows-1252"
        }
    }
}

/// The line ending a file uses. The editor stores `\n` and writes this back.
public enum LineEnding: String, Equatable, Sendable {
    case lf
    case crlf
    case cr

    public var label: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    var characters: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

/// Text after decoding, with the encoding and line ending to use on the next save.
public struct DecodedText: Equatable, Sendable {
    public var text: String
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
    /// More than one ending was present. `lineEnding` is the one that appeared most.
    public var mixedLineEndings: Bool

    public init(text: String, encoding: TextEncoding, lineEnding: LineEnding, mixedLineEndings: Bool) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.mixedLineEndings = mixedLineEndings
    }
}

/// Reads and writes the bytes of a text file without changing its encoding or line endings.
public enum TextBytes {
    public enum EncodingError: Error, Equatable {
        /// A character in the editor cannot be stored in the file's encoding.
        case unrepresentable
    }

    /// `allowLegacy` decodes Windows-1252 when the bytes are not Unicode.
    /// Callers pass true for names that are already known to be text.
    public static func decode(_ data: Data, allowLegacy: Bool = false) -> DecodedText? {
        if data.isEmpty {
            return DecodedText(text: "", encoding: .utf8, lineEnding: .lf, mixedLineEndings: false)
        }
        if let unicode = decodeUnicode(data) {
            let endings = splitEndings(unicode.text)
            return DecodedText(
                text: endings.text,
                encoding: unicode.encoding,
                lineEnding: endings.ending,
                mixedLineEndings: endings.mixed
            )
        }
        guard allowLegacy, !data.contains(0), let legacy = String(data: data, encoding: .windowsCP1252) else {
            return nil
        }
        let endings = splitEndings(legacy)
        return DecodedText(
            text: endings.text,
            encoding: .windows1252,
            lineEnding: endings.ending,
            mixedLineEndings: endings.mixed
        )
    }

    public static func encode(_ text: String, encoding: TextEncoding, lineEnding: LineEnding) -> Data? {
        let restored = restore(text, ending: lineEnding)
        switch encoding {
        case .utf8:
            return Data(restored.utf8)
        case .utf8BOM:
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(contentsOf: restored.utf8)
            return data
        case .utf16LE:
            return utf16(restored, bigEndian: false, bom: false)
        case .utf16LEBOM:
            return utf16(restored, bigEndian: false, bom: true)
        case .utf16BE:
            return utf16(restored, bigEndian: true, bom: false)
        case .utf16BEBOM:
            return utf16(restored, bigEndian: true, bom: true)
        case .windows1252:
            return restored.data(using: .windowsCP1252)
        }
    }

    /// A UTF-16 byte-order mark, or a strong UTF-16 pattern when `allowHeuristic` is set.
    /// A UTF-32 mark is not UTF-16.
    public static func looksLikeUTF16(_ data: Data, allowHeuristic: Bool) -> Bool {
        if data.starts(with: [0xFF, 0xFE]) {
            if data.count >= 4, data[2] == 0, data[3] == 0 { return false }
            return data.count >= 2
        }
        if data.starts(with: [0xFE, 0xFF]) { return data.count >= 2 }
        guard allowHeuristic else { return false }
        return heuristicEndian(data) != nil
    }

    private struct UnicodeText {
        var text: String
        var encoding: TextEncoding
    }

    private static func decodeUnicode(_ data: Data) -> UnicodeText? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = data.dropFirst(3)
            guard let text = String(data: body, encoding: .utf8) else { return nil }
            return UnicodeText(text: text, encoding: .utf8BOM)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            if data.count >= 4, data[2] == 0, data[3] == 0 { return nil }
            guard let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else { return nil }
            return UnicodeText(text: text, encoding: .utf16LEBOM)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else { return nil }
            return UnicodeText(text: text, encoding: .utf16BEBOM)
        }
        if String(data: data, encoding: .utf8) != nil, let text = String(data: data, encoding: .utf8) {
            return UnicodeText(text: text, encoding: .utf8)
        }
        if let endian = heuristicEndian(data) {
            let encoding: String.Encoding = endian.big ? .utf16BigEndian : .utf16LittleEndian
            guard let text = String(data: data, encoding: encoding) else { return nil }
            return UnicodeText(text: text, encoding: endian.big ? .utf16BE : .utf16LE)
        }
        return nil
    }

    private struct Endian {
        var big: Bool
    }

    /// Even length, many zero bytes on one side, and the other side mostly ASCII.
    /// Little-endian ASCII has the zero on the odd byte.
    private static func heuristicEndian(_ data: Data) -> Endian? {
        guard data.count >= 8, data.count.isMultiple(of: 2) else { return nil }
        let bytes = [UInt8](data)
        var oddZeros = 0
        var evenZeros = 0
        var oddASCII = 0
        var evenASCII = 0
        let pairs = bytes.count / 2
        for index in stride(from: 0, to: bytes.count, by: 2) {
            if bytes[index] == 0 { evenZeros += 1 }
            if isASCIIText(bytes[index]) { evenASCII += 1 }
            if bytes[index + 1] == 0 { oddZeros += 1 }
            if isASCIIText(bytes[index + 1]) { oddASCII += 1 }
        }
        let threshold = max(2, pairs / 2)
        if oddZeros >= threshold, evenASCII >= threshold { return Endian(big: false) }
        if evenZeros >= threshold, oddASCII >= threshold { return Endian(big: true) }
        return nil
    }

    private static func isASCIIText(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || (byte >= 0x20 && byte <= 0x7E)
    }

    private static func utf16(_ text: String, bigEndian: Bool, bom: Bool) -> Data {
        var data = Data()
        if bom {
            data.append(contentsOf: bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE])
        }
        for unit in text.utf16 {
            let high = UInt8((unit >> 8) & 0xFF)
            let low = UInt8(unit & 0xFF)
            if bigEndian {
                data.append(high)
                data.append(low)
            } else {
                data.append(low)
                data.append(high)
            }
        }
        return data
    }

    private struct EndingSplit {
        var text: String
        var ending: LineEnding
        var mixed: Bool
    }

    static func splitEndings(_ text: String) -> EndingSplit {
        var lf = 0
        var crlf = 0
        var cr = 0
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\r" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\n" {
                    crlf += 1
                    result.append("\n")
                    index = text.index(after: next)
                    continue
                }
                cr += 1
                result.append("\n")
            } else if character == "\n" {
                lf += 1
                result.append("\n")
            } else {
                result.append(character)
            }
            index = text.index(after: index)
        }
        let kinds = [lf > 0, crlf > 0, cr > 0].filter { $0 }.count
        let ending: LineEnding
        if crlf >= lf && crlf >= cr && crlf > 0 {
            ending = .crlf
        } else if cr > lf && cr > crlf {
            ending = .cr
        } else {
            ending = .lf
        }
        return EndingSplit(text: result, ending: ending, mixed: kinds > 1)
    }

    static func restore(_ text: String, ending: LineEnding) -> String {
        guard ending != .lf else { return text }
        let unit = ending.characters
        var result = ""
        result.reserveCapacity(text.count + text.count / 8)
        for character in text {
            if character == "\n" {
                result.append(unit)
            } else if character != "\r" {
                result.append(character)
            }
        }
        return result
    }
}
