import Foundation

/// The caret and selection, for the status bar.
public struct EditorCaret: Equatable, Sendable {
    public var line: Int
    public var column: Int
    /// Characters in the selection. Zero when the selection covers more than one line.
    public var selectedCharacters: Int
    /// Lines in the selection. Zero when the caret is only a caret, or the selection stays on one line.
    public var selectedLines: Int

    public init(line: Int = 1, column: Int = 1, selectedCharacters: Int = 0, selectedLines: Int = 0) {
        self.line = line
        self.column = column
        self.selectedCharacters = selectedCharacters
        self.selectedLines = selectedLines
    }

    /// `utf16Location` and `utf16Length` are an `NSTextView` selection.
    /// The column counts characters, so one Chinese character is one column.
    public static func measure(text: String, utf16Location: Int, utf16Length: Int) -> EditorCaret {
        measure(text: text, utf16Location: utf16Location, utf16Length: utf16Length, index: LineIndex(text))
    }

    /// Uses a line index that already exists, so a caret move does not scan the whole file.
    public static func measure(text: String, utf16Location: Int, utf16Length: Int, index: LineIndex) -> EditorCaret {
        let ns = text as NSString
        let location = min(max(0, utf16Location), ns.length)
        let length = min(max(0, utf16Length), ns.length - location)
        let line = index.line(at: location)
        let lineStart = index.starts[max(0, line - 1)]
        let column = characterCount(ns, from: lineStart, to: location) + 1
        if length == 0 {
            return EditorCaret(line: line, column: column, selectedCharacters: 0, selectedLines: 0)
        }
        let end = location + length
        let endLine = index.line(at: max(location, end - 1))
        if endLine > line {
            return EditorCaret(
                line: line,
                column: column,
                selectedCharacters: 0,
                selectedLines: endLine - line + 1
            )
        }
        return EditorCaret(
            line: line,
            column: column,
            selectedCharacters: characterCount(ns, from: location, to: end),
            selectedLines: 0
        )
    }

    private static func characterCount(_ ns: NSString, from: Int, to: Int) -> Int {
        guard to > from, from >= 0, to <= ns.length else { return 0 }
        return ns.substring(with: NSRange(location: from, length: to - from)).count
    }
}

/// A line and column from Go to Line. Columns count characters, starting at 1.
public struct GoToPosition: Equatable, Sendable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int = 1) {
        self.line = max(1, line)
        self.column = max(1, column)
    }

    /// `12`, `12:4`, and `12,4`. Anything else is nil.
    public static func parse(_ raw: String) -> GoToPosition? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "," || $0 == "：" })
        guard parts.count == 1 || parts.count == 2 else { return nil }
        guard let line = Int(parts[0].trimmingCharacters(in: .whitespaces)), line > 0 else { return nil }
        if parts.count == 1 {
            return GoToPosition(line: line, column: 1)
        }
        guard let column = Int(parts[1].trimmingCharacters(in: .whitespaces)), column > 0 else { return nil }
        return GoToPosition(line: line, column: column)
    }

    /// UTF-16 offset of the character column on that source line. The line is clamped to the text.
    public static func utf16Offset(in text: String, line: Int, column: Int) -> Int {
        let index = LineIndex(text)
        let lineIndex = min(max(line, 1), index.count) - 1
        let start = index.starts[lineIndex]
        let ns = text as NSString
        guard column > 1, start < ns.length else { return start }
        var cursor = start
        var seen = 1
        while cursor < ns.length, seen < column {
            let unit = ns.character(at: cursor)
            if unit == 0x0A || unit == 0x0D { break }
            cursor = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: cursor))
            seen += 1
        }
        return min(cursor, ns.length)
    }
}
