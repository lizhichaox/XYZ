import Foundation

/// Word and character counts for the status line.
///
/// Chinese, Japanese, and Korean are counted a character at a time, the way 字数 is counted;
/// other scripts count runs of letters and digits as words. Markdown punctuation counts as
/// neither, so `**bold**` is one word.
public struct TextStatistics: Equatable, Sendable {
    /// CJK characters.
    public var ideographs: Int
    /// Words in other scripts.
    public var words: Int
    /// Characters other than whitespace.
    public var characters: Int

    public init(ideographs: Int = 0, words: Int = 0, characters: Int = 0) {
        self.ideographs = ideographs
        self.words = words
        self.characters = characters
    }

    /// Ideographs plus words, the single number a writer usually means by "word count".
    public var total: Int { ideographs + words }

    /// Minutes to read at about 400 CJK characters or 230 words a minute. Zero for an empty note.
    public var readingMinutes: Int {
        guard total > 0 else { return 0 }
        let minutes = Double(ideographs) / 400 + Double(words) / 230
        return max(1, Int(minutes.rounded(.up)))
    }

    public static func count(_ text: String) -> TextStatistics {
        var result = TextStatistics()
        var inWord = false
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            if properties.isWhitespace {
                inWord = false
                continue
            }
            if isCJK(scalar) {
                result.ideographs += 1
                inWord = false
            } else if properties.isAlphabetic || properties.numericType != nil || (scalar == "'" && inWord) {
                if !inWord {
                    result.words += 1
                    inWord = true
                }
            } else {
                inWord = false
            }
        }
        // Characters, not scalars, so an emoji or an accented letter counts once.
        result.characters = text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0x20000...0x323AF: // CJK Extensions B to H
            return true
        default:
            return false
        }
    }
}

/// Where each source line starts, in UTF-16 offsets, for line numbers beside Source.
/// `\n`, `\r\n`, and a lone `\r` each end a line, as in ``EditorScrollAnchor``.
public struct LineIndex: Equatable, Sendable {
    public private(set) var starts: [Int]

    public init(_ text: String) {
        let ns = text as NSString
        var starts = [0]
        var index = 0
        while index < ns.length {
            let character = ns.character(at: index)
            if character == 0x0A {
                starts.append(index + 1)
            } else if character == 0x0D {
                if index + 1 < ns.length, ns.character(at: index + 1) == 0x0A {
                    index += 1
                }
                starts.append(index + 1)
            }
            index += 1
        }
        self.starts = starts
    }

    /// Lines in the text. A trailing line break starts one more, empty line.
    public var count: Int { starts.count }

    /// The 1-based line holding the UTF-16 offset.
    public func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low + 1
    }
}
