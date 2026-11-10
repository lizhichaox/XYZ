import Foundation

/// Markdown heading folds for the editor.
///
/// Obsidian's source mode and VS Code's Markdown folding both collapse a section by its
/// heading: the heading hides the lines below it until the next heading of the same or a
/// higher level. Only ATX headings (`#` through `######`) fold; a setext heading keeps its
/// underline visible, so it has no fold. Fenced code and YAML front matter are skipped, so
/// a `#` comment inside either is not a heading.
public enum MarkdownFolding {
    public static func folds(in text: String) -> [CodeFolding.Fold] {
        // One UTF-16 copy, then direct indexing: `NSString.character(at:)` per character
        // costs several milliseconds on a large note, and this runs on every typing pause.
        let units = Array(text.utf16)
        let length = units.count
        guard length > 0 else { return [] }

        var lineStarts: [Int] = []
        var lineEnds: [Int] = []
        var contentEnds: [Int] = []
        var hasContent: [Bool] = []
        var lineStart = 0
        while lineStart < length {
            var contentEnd = lineStart
            var content = false
            while contentEnd < length {
                let unit = units[contentEnd]
                if unit == 0x0A || unit == 0x0D { break }
                if unit != 0x20 && unit != 0x09 { content = true }
                contentEnd += 1
            }
            var lineEnd = contentEnd
            if lineEnd < length, units[lineEnd] == 0x0D { lineEnd += 1 }
            if lineEnd < length, units[lineEnd] == 0x0A { lineEnd += 1 }
            lineStarts.append(lineStart)
            lineEnds.append(lineEnd)
            contentEnds.append(contentEnd)
            hasContent.append(content)
            lineStart = lineEnd
        }
        let count = lineStarts.count
        guard count > 1 else { return [] }

        // A leading `---` block is front matter only when a closing `---` or `...` line
        // exists; otherwise the first line is a horizontal rule.
        var frontMatterEnd = -1
        if isDelimiter(units, start: lineStarts[0], end: contentEnds[0], marker: 0x2D) {
            for index in 1..<count {
                if isDelimiter(units, start: lineStarts[index], end: contentEnds[index], marker: 0x2D)
                    || isDelimiter(units, start: lineStarts[index], end: contentEnds[index], marker: 0x2E) {
                    frontMatterEnd = index
                    break
                }
            }
        }

        var levels: [Int] = []
        levels.reserveCapacity(count)
        var fenceMarker: UInt16 = 0
        var fenceCount = 0
        for index in 0..<count {
            if index <= frontMatterEnd {
                levels.append(0)
                continue
            }
            let start = lineStarts[index]
            let end = contentEnds[index]
            if fenceMarker != 0 {
                levels.append(0)
                if closesFence(units, start: start, end: end, marker: fenceMarker, count: fenceCount) {
                    fenceMarker = 0
                    fenceCount = 0
                }
            } else if let opening = fenceOpening(units, start: start, end: end) {
                levels.append(0)
                fenceMarker = opening.marker
                fenceCount = opening.count
            } else {
                levels.append(headingLevel(units, start: start, end: end))
            }
        }

        // The nearest heading to the right whose level is not deeper, in one pass.
        var boundary = [Int](repeating: count, count: count)
        var stack: [(level: Int, index: Int)] = []
        for index in stride(from: count - 1, through: 0, by: -1) {
            let level = levels[index]
            guard level > 0 else { continue }
            while let top = stack.last, top.level > level { stack.removeLast() }
            boundary[index] = stack.last?.index ?? count
            stack.append((level, index))
        }

        // The last non-blank line at or before each line, so a section's trailing blank
        // lines stay visible and a heading followed only by blanks has no fold.
        var lastContent = [Int](repeating: -1, count: count)
        var seen = -1
        for index in 0..<count {
            if hasContent[index] { seen = index }
            lastContent[index] = seen
        }

        var folds: [CodeFolding.Fold] = []
        for index in 0..<count where levels[index] > 0 {
            let end = boundary[index]
            guard end > index + 1 else { continue }
            let last = lastContent[end - 1]
            guard last > index else { continue }
            let hiddenStart = lineEnds[index]
            let hiddenEnd = lineEnds[last]
            guard hiddenEnd > hiddenStart else { continue }
            folds.append(CodeFolding.Fold(
                headerLine: index + 1,
                lastLine: last + 1,
                innerRange: NSRange(location: hiddenStart, length: hiddenEnd - hiddenStart),
                lineCount: last - index
            ))
        }
        return folds
    }

    /// True for a line that is exactly three of `marker` after up to three spaces.
    private static func isDelimiter(_ units: [UInt16], start: Int, end: Int, marker: UInt16) -> Bool {
        var index = start
        var spaces = 0
        while index < end, units[index] == 0x20 {
            spaces += 1
            if spaces > 3 { return false }
            index += 1
        }
        var run = 0
        while index < end, units[index] == marker {
            run += 1
            index += 1
        }
        guard run == 3 else { return false }
        while index < end {
            let unit = units[index]
            if unit != 0x20 && unit != 0x09 { return false }
            index += 1
        }
        return true
    }

    /// 1 through 6 for an ATX heading, 0 for anything else. Up to three leading spaces are
    /// allowed; a tab or a fourth space makes the line indented code.
    private static func headingLevel(_ units: [UInt16], start: Int, end: Int) -> Int {
        var index = start
        var spaces = 0
        while index < end, units[index] == 0x20 {
            spaces += 1
            if spaces > 3 { return 0 }
            index += 1
        }
        var hashes = 0
        while index < end, units[index] == 0x23 {
            hashes += 1
            if hashes > 6 { return 0 }
            index += 1
        }
        guard hashes > 0 else { return 0 }
        guard index < end else { return hashes }
        let next = units[index]
        return next == 0x20 || next == 0x09 ? hashes : 0
    }

    private static func fenceOpening(_ units: [UInt16], start: Int, end: Int) -> (marker: UInt16, count: Int)? {
        var index = start
        var spaces = 0
        while index < end, units[index] == 0x20 {
            spaces += 1
            if spaces > 3 { return nil }
            index += 1
        }
        guard index < end else { return nil }
        let marker = units[index]
        guard marker == 0x60 || marker == 0x7E else { return nil }
        var count = 0
        while index < end, units[index] == marker {
            count += 1
            index += 1
        }
        guard count >= 3 else { return nil }
        // A backtick fence's info string cannot contain a backtick.
        if marker == 0x60 {
            var probe = index
            while probe < end {
                if units[probe] == 0x60 { return nil }
                probe += 1
            }
        }
        return (marker, count)
    }

    private static func closesFence(
        _ units: [UInt16],
        start: Int,
        end: Int,
        marker: UInt16,
        count: Int
    ) -> Bool {
        var index = start
        var spaces = 0
        while index < end, units[index] == 0x20 {
            spaces += 1
            if spaces > 3 { return false }
            index += 1
        }
        var run = 0
        while index < end, units[index] == marker {
            run += 1
            index += 1
        }
        guard run >= count else { return false }
        while index < end {
            let unit = units[index]
            if unit != 0x20 && unit != 0x09 { return false }
            index += 1
        }
        return true
    }
}
