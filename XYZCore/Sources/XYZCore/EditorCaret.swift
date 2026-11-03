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
        let ns = text as NSString
        let location = min(max(0, utf16Location), ns.length)
        let length = min(max(0, utf16Length), ns.length - location)
        let index = LineIndex(text)
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
