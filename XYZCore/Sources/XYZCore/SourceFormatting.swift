import Foundation

/// The list a Format command makes: `- `, `1. `, or `- [ ] `.
public enum SourceListKind: Equatable, Sendable {
    case bullet
    case ordered
    case task
}

/// Line formats for the Format menu: headings, quotes, lists, code blocks, tables, and links.
///
/// Each command is one undoable replacement over the lines the selection touches, like the
/// typing behavior above. Lines inside a code fence are left alone.
extension SourceEditing {
    /// Sets the heading level of the selected lines. Level 0 makes them paragraphs.
    /// Choosing the level the lines already have turns the heading off, as in Typora.
    public static func setHeading(level: Int, in text: String, selection: SourceRange) -> SourceReplacement? {
        let level = min(max(level, 0), 6)
        return rewriteLines(in: text, selection: selection) { lines in
            let parsed = lines.map(headingPrefix)
            let filled = lines.indices.filter { !isBlank(lines[$0]) }
            let already = level > 0 && !filled.isEmpty && filled.allSatisfy { parsed[$0]?.level == level }
            let single = lines.count == 1
            return lines.indices.map { index in
                let line = lines[index]
                if isBlank(line) && !single { return line }
                let body = parsed[index].map { (line as NSString).substring(from: $0.bodyStart) }
                    ?? line.trimmingCharacters(in: .whitespaces)
                if level == 0 || already { return body }
                return String(repeating: "#", count: level) + " " + body
            }
        }
    }

    /// Adds `> ` to the selected lines, or removes it when every line is already quoted.
    public static func toggleQuote(in text: String, selection: SourceRange) -> SourceReplacement? {
        rewriteLines(in: text, selection: selection) { lines in
            let filled = lines.filter { !isBlank($0) }
            let quoted = !filled.isEmpty && filled.allSatisfy { quotePrefix($0) != nil }
            return lines.map { line in
                if quoted {
                    guard let prefix = quotePrefix(line) else { return line }
                    return (line as NSString).substring(from: prefix)
                }
                if isBlank(line) {
                    return lines.count == 1 ? "> " : ">"
                }
                return "> " + line
            }
        }
    }

    /// Makes the selected lines a list of `kind`, renumbering an ordered list from 1.
    /// When every line is already that kind of item, the markers are removed.
    public static func toggleList(_ kind: SourceListKind, in text: String, selection: SourceRange) -> SourceReplacement? {
        rewriteLines(in: text, selection: selection) { lines in
            let markers = lines.map(listMarker)
            let filled = lines.indices.filter { !isBlank(lines[$0]) }
            let same = !filled.isEmpty && filled.allSatisfy { markers[$0]?.kind == kind }
            var number = 1
            return lines.indices.map { index in
                let line = lines[index] as NSString
                if isBlank(lines[index]) && lines.count > 1 { return lines[index] }
                let indent: String
                let body: String
                if let marker = markers[index] {
                    indent = line.substring(to: marker.indent)
                    body = line.substring(from: marker.bodyStart)
                } else {
                    let trimmed = (lines[index] as String).drop { $0 == " " || $0 == "\t" }
                    indent = String((lines[index] as String).prefix(lines[index].count - trimmed.count))
                    body = String(trimmed)
                }
                if same { return indent + body }
                let prefix: String
                switch kind {
                case .bullet: prefix = "- "
                case .task: prefix = "- [ ] "
                case .ordered: prefix = "\(number). "
                }
                number += 1
                return indent + prefix + body
            }
        }
    }

    /// Fences the selected lines, or an empty line, with ``` and leaves the caret where the language goes.
    public static func insertCodeBlock(in text: String, selection: SourceRange) -> SourceReplacement? {
        let ns = text as NSString
        guard contains(selection, length: ns.length) else { return nil }
        let span = coveringLines(in: ns, selection: selection)
        guard !insideFence(ns, before: span.location) else { return nil }
        let lines = collectLines(ns, span: span)
        let body = lines.map(\.content).joined(separator: "\n")
        let trailing = lines.last?.newline ?? ""
        let fenced = "```\n" + body + "\n```" + trailing
        return SourceReplacement(
            range: SourceRange(location: span.location, length: span.length),
            text: fenced,
            selection: SourceRange(location: span.location + 3, length: 0)
        )
    }

    /// A two-column table with a header row and one body row, caret in the first header cell.
    /// On a line with text, the table goes below it after a blank line.
    public static func insertTable(in text: String, selection: SourceRange) -> SourceReplacement? {
        let ns = text as NSString
        guard contains(selection, length: ns.length) else { return nil }
        let line = lineRange(in: ns, at: selection.end)
        guard !insideFence(ns, before: line.location) else { return nil }
        let parts = split(ns, line)
        let table = "|  |  |\n| --- | --- |\n|  |  |"
        if parts.content.length == 0 || isBlank(ns.substring(with: parts.content)) {
            return SourceReplacement(
                range: SourceRange(location: parts.content.location, length: parts.content.length),
                text: table,
                selection: SourceRange(location: parts.content.location + 2, length: 0)
            )
        }
        let end = NSMaxRange(parts.content)
        return SourceReplacement(
            range: SourceRange(location: end, length: 0),
            text: "\n\n" + table,
            selection: SourceRange(location: end + 4, length: 0)
        )
    }

    /// `[selection]()` with the caret in the parentheses. A selected web address becomes the
    /// destination instead, and with nothing selected the caret goes in the brackets.
    public static func insertLink(in text: String, selection: SourceRange) -> SourceReplacement? {
        let ns = text as NSString
        guard contains(selection, length: ns.length) else { return nil }
        let selected = ns.substring(with: NSRange(location: selection.location, length: selection.length))
        if isWebAddress(selected) {
            return SourceReplacement(
                range: selection,
                text: "[](" + selected + ")",
                selection: SourceRange(location: selection.location + 1, length: 0)
            )
        }
        let link = "[" + selected + "]()"
        let caret = selected.isEmpty ? selection.location + 1 : selection.location + 1 + (selected as NSString).length + 2
        return SourceReplacement(range: selection, text: link, selection: SourceRange(location: caret, length: 0))
    }

    // MARK: - Lines

    private struct Line {
        var content: String
        var newline: String
    }

    private static func collectLines(_ ns: NSString, span: NSRange) -> [Line] {
        var lines: [Line] = []
        var cursor = span.location
        while true {
            let line = lineRange(in: ns, at: cursor)
            let parts = split(ns, line)
            lines.append(Line(content: ns.substring(with: parts.content), newline: ns.substring(with: parts.newline)))
            let next = NSMaxRange(line)
            if next <= cursor || next >= NSMaxRange(span) { break }
            cursor = next
        }
        return lines
    }

    /// Replaces the lines the selection covers with `transform`'s lines (same count).
    /// A caret moves with its line's prefix. A selection keeps covering the rewritten lines.
    private static func rewriteLines(
        in text: String,
        selection: SourceRange,
        _ transform: ([String]) -> [String]
    ) -> SourceReplacement? {
        let ns = text as NSString
        guard contains(selection, length: ns.length) else { return nil }
        let span = coveringLines(in: ns, selection: selection)
        guard !insideFence(ns, before: span.location) else { return nil }
        let lines = collectLines(ns, span: span)
        let rewritten = transform(lines.map(\.content))
        guard rewritten.count == lines.count else { return nil }
        guard rewritten != lines.map(\.content) else { return nil }
        var text = ""
        for (index, line) in lines.enumerated() {
            text += rewritten[index] + line.newline
        }
        let next: SourceRange
        if selection.length == 0 {
            let delta = (rewritten[0] as NSString).length - (lines[0].content as NSString).length
            next = SourceRange(location: max(span.location, selection.location + delta), length: 0)
        } else {
            let trailing = (lines.last?.newline as NSString?)?.length ?? 0
            next = SourceRange(location: span.location, length: (text as NSString).length - trailing)
        }
        return SourceReplacement(
            range: SourceRange(location: span.location, length: span.length),
            text: text,
            selection: next
        )
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func leadingSpaces(_ line: NSString, limit: Int) -> Int {
        var index = 0
        while index < line.length, index < limit {
            let character = line.character(at: index)
            guard character == 0x20 || character == 0x09 else { break }
            index += 1
        }
        return index
    }

    /// `#` to `######` after up to three spaces, then a space, a tab, or the end of the line.
    private static func headingPrefix(_ line: String) -> (level: Int, bodyStart: Int)? {
        let ns = line as NSString
        var index = leadingSpaces(ns, limit: 3)
        var hashes = 0
        while index < ns.length, ns.character(at: index) == 0x23 {
            hashes += 1
            index += 1
        }
        guard (1...6).contains(hashes) else { return nil }
        if index == ns.length { return (hashes, index) }
        let gap = ns.character(at: index)
        guard gap == 0x20 || gap == 0x09 else { return nil }
        while index < ns.length, ns.character(at: index) == 0x20 || ns.character(at: index) == 0x09 {
            index += 1
        }
        return (hashes, index)
    }

    /// UTF-16 length of `>` and one following space, after up to three spaces.
    private static func quotePrefix(_ line: String) -> Int? {
        let ns = line as NSString
        let index = leadingSpaces(ns, limit: 3)
        guard index < ns.length, ns.character(at: index) == 0x3E else { return nil }
        if index + 1 < ns.length, ns.character(at: index + 1) == 0x20 {
            return index + 2
        }
        return index + 1
    }

    private static func listMarker(_ line: String) -> (kind: SourceListKind, indent: Int, bodyStart: Int)? {
        let ns = line as NSString
        let indent = leadingSpaces(ns, limit: Int.max)
        guard indent < ns.length else { return nil }
        let first = ns.character(at: indent)
        if first == 0x2D || first == 0x2A || first == 0x2B {
            let gap = indent + 1
            guard gap < ns.length else { return nil }
            let space = ns.character(at: gap)
            guard space == 0x20 || space == 0x09 else { return nil }
            let body = gap + 1
            if body + 2 < ns.length,
               ns.character(at: body) == 0x5B,
               [0x20, 0x78, 0x58].contains(ns.character(at: body + 1)),
               ns.character(at: body + 2) == 0x5D {
                var start = body + 3
                if start < ns.length, ns.character(at: start) == 0x20 { start += 1 }
                return (.task, indent, start)
            }
            return (.bullet, indent, body)
        }
        var cursor = indent
        while cursor < ns.length, cursor - indent < 9, (0x30...0x39).contains(ns.character(at: cursor)) {
            cursor += 1
        }
        guard cursor > indent, cursor + 1 < ns.length else { return nil }
        let punct = ns.character(at: cursor)
        guard punct == 0x2E || punct == 0x29 else { return nil }
        let space = ns.character(at: cursor + 1)
        guard space == 0x20 || space == 0x09 else { return nil }
        return (.ordered, indent, cursor + 2)
    }

    private static func isWebAddress(_ string: String) -> Bool {
        let lowered = string.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return false }
        return !string.contains { $0.isWhitespace }
    }
}
