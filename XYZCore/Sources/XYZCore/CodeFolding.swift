import Foundation

/// Indentation-based fold ranges for code and structured text.
///
/// One pass over the lines: a line opens a fold when the lines after it are indented
/// deeper, and the fold closes when a line comes back to the header's indentation. Blank
/// lines never close a fold, so a function separated by empty lines stays one block.
public enum CodeFolding {
    public struct Fold: Equatable, Sendable {
        /// 1-based line of the block's first line, which stays visible.
        public var headerLine: Int
        /// 1-based last line folded away (always greater than `headerLine`).
        public var lastLine: Int
        /// The hidden characters, without the header's line ending.
        public var innerRange: NSRange
        /// Hidden line count, for the placeholder label.
        public var lineCount: Int

        public init(headerLine: Int, lastLine: Int, innerRange: NSRange, lineCount: Int) {
            self.headerLine = headerLine
            self.lastLine = lastLine
            self.innerRange = innerRange
            self.lineCount = lineCount
        }
    }

    /// Markdown folds by heading level, not indentation, so it is handled by
    /// `MarkdownFolding` and never here.
    public static func supports(_ language: SyntaxLanguage) -> Bool {
        switch language {
        case .plain, .markdown, .csv, .log:
            return false
        default:
            return true
        }
    }

    public static func folds(in text: String, language: SyntaxLanguage) -> [Fold] {
        guard supports(language) else { return [] }
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var lines: [(range: NSRange, contentRange: NSRange, indent: Int?)] = []
        var cursor = 0
        while cursor < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let content = lineRange.length > 0 && ns.character(at: NSMaxRange(lineRange) - 1) == 0x0A
                ? NSRange(location: lineRange.location, length: lineRange.length - 1)
                : lineRange
            var index = content.location
            var indent = 0
            var hasContent = false
            while index < NSMaxRange(content) {
                let character = ns.character(at: index)
                if character == 0x20 {
                    indent += 1
                } else if character == 0x09 {
                    indent += 4
                } else if character == 0x0D {
                    // ignore
                } else {
                    hasContent = true
                    break
                }
                index += 1
            }
            lines.append((lineRange, content, hasContent ? indent : nil))
            let next = NSMaxRange(lineRange)
            if next <= cursor { break }
            cursor = next
        }
        guard lines.count > 1 else { return [] }
        var folds: [Fold] = []
        var stack: [(indent: Int, line: Int)] = []
        func isCloser(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { return false }
            if first == "}" || first == "]" || first == ")" { return true }
            return trimmed == "end" || trimmed.hasPrefix("end ")
        }
        func lineContent(_ index: Int) -> String {
            ns.substring(with: lines[index].contentRange)
        }
        func closesOnly(_ index: Int) -> Bool {
            let trimmed = lineContent(index).trimmingCharacters(in: .whitespaces)
            return trimmed == "}" || trimmed == "]" || trimmed == ")" || trimmed == "end"
        }
        func close(_ header: (indent: Int, line: Int), before: Int, closerIndent: Int?, closerLine: Bool) {
            // A fold only exists when the first line after the header is indented deeper;
            // otherwise the header is a plain statement inside a block.
            var probe = header.line + 1
            while probe < lines.count, lines[probe].indent == nil { probe += 1 }
            guard probe < lines.count, let probeIndent = lines[probe].indent,
                  probeIndent > header.indent
            else { return }
            var last = before - 1
            if closerLine, let closerIndent, closerIndent <= header.indent {
                // The line that closes the block is hidden with it, as VS Code does.
                last = before
            } else {
                while last > header.line, lines[last].indent == nil { last -= 1 }
            }
            guard last > header.line else { return }
            let hiddenStart = NSMaxRange(lines[header.line].range)
            let hiddenEnd = NSMaxRange(lines[last].range)
            guard hiddenEnd > hiddenStart else { return }
            folds.append(Fold(
                headerLine: header.line + 1,
                lastLine: last + 1,
                innerRange: NSRange(location: hiddenStart, length: hiddenEnd - hiddenStart),
                lineCount: last - header.line
            ))
        }
        for (index, line) in lines.enumerated() {
            guard let indent = line.indent else { continue }
            let closer = isCloser(lineContent(index))
            while let top = stack.last, top.indent >= indent {
                stack.removeLast()
                close(top, before: index, closerIndent: indent, closerLine: closer)
            }
            // A bare closing line ends a block; it must not open a new one.
            if closesOnly(index) { continue }
            stack.append((indent, index))
        }
        while let top = stack.popLast() {
            close(top, before: lines.count, closerIndent: nil, closerLine: false)
        }
        // Nested folds are reported too; the editor decides which one a line belongs to by
        // taking the innermost header.
        return folds.sorted { $0.headerLine < $1.headerLine }
    }
}
