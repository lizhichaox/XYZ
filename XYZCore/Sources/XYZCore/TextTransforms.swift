import Foundation

public enum TextCase: Equatable, Sendable {
    case upper
    case lower
    case title
}

/// Line and selection edits. One value is one undo. Newlines already in the text stay as they are.
public enum TextTransforms {
    public static func duplicateLine(in text: String, selection: SourceRange, above: Bool) -> SourceReplacement? {
        let ns = text as NSString
        guard let lines = coveringLines(ns, selection) else { return nil }
        let block = ns.substring(with: lines)
        let bare = !block.hasSuffix("\n") && !block.hasSuffix("\r")
        let insertion = above ? (bare ? block + "\n" : block) : (bare ? "\n" + block : block)
        let at = above ? lines.location : NSMaxRange(lines)
        let caret = above ? lines.location : (bare ? at + 1 : at)
        return SourceReplacement(
            range: SourceRange(location: at, length: 0),
            text: insertion,
            selection: SourceRange(location: caret, length: lines.length)
        )
    }

    public static func moveLine(in text: String, selection: SourceRange, up: Bool) -> SourceReplacement? {
        let ns = text as NSString
        guard let lines = coveringLines(ns, selection) else { return nil }
        if up {
            guard lines.location > 0 else { return nil }
            let previous = ns.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            let block = ns.substring(with: lines)
            let moved = block + ns.substring(with: previous)
            return SourceReplacement(
                range: SourceRange(location: previous.location, length: NSMaxRange(lines) - previous.location),
                text: moved,
                selection: SourceRange(location: previous.location, length: lines.length)
            )
        }
        guard NSMaxRange(lines) < ns.length else { return nil }
        let next = ns.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
        let block = ns.substring(with: lines)
        let moved = ns.substring(with: next) + block
        return SourceReplacement(
            range: SourceRange(location: lines.location, length: NSMaxRange(next) - lines.location),
            text: moved,
            selection: SourceRange(location: lines.location + next.length, length: lines.length)
        )
    }

    public static func deleteLine(in text: String, selection: SourceRange) -> SourceReplacement? {
        let ns = text as NSString
        guard let lines = coveringLines(ns, selection), lines.length > 0 else { return nil }
        return SourceReplacement(
            range: SourceRange(location: lines.location, length: lines.length),
            text: "",
            selection: SourceRange(location: lines.location, length: 0)
        )
    }

    /// Adds `prefix` after each line's indent, or removes it when every line already has it.
    /// `suffix` closes a comment that is not a line marker, such as HTML.
    public static func toggleComment(
        in text: String,
        selection: SourceRange,
        prefix: String,
        suffix: String = ""
    ) -> SourceReplacement? {
        let ns = text as NSString
        guard let lines = coveringLines(ns, selection), !prefix.isEmpty else { return nil }
        let body = ns.substring(with: lines)
        let rows = body.components(separatedBy: "\n")
        let commenting = !rows.allSatisfy { row in row.isEmpty || hasComment(row, prefix: prefix, suffix: suffix) }
        var rebuilt: [String] = []
        rebuilt.reserveCapacity(rows.count)
        for row in rows {
            if row.isEmpty {
                rebuilt.append(row)
                continue
            }
            if commenting {
                let indent = leadingIndent(row)
                let rest = String(row.dropFirst(indent.count))
                rebuilt.append(indent + prefix + rest + suffix)
            } else {
                rebuilt.append(removingComment(row, prefix: prefix, suffix: suffix))
            }
        }
        let replacement = rebuilt.joined(separator: "\n")
        guard replacement != body else { return nil }
        return SourceReplacement(
            range: SourceRange(location: lines.location, length: lines.length == 0 ? 0 : (body as NSString).length),
            text: replacement,
            selection: SourceRange(location: lines.location, length: (replacement as NSString).length)
        )
    }

    public static func indentLines(in text: String, selection: SourceRange, outdent: Bool) -> SourceReplacement? {
        let ns = text as NSString
        guard let lines = coveringLines(ns, selection) else { return nil }
        let body = ns.substring(with: lines)
        let rows = body.components(separatedBy: "\n")
        let rebuilt = rows.map { row -> String in
            if outdent { return removeIndent(row) }
            if row.isEmpty { return row }
            return "    " + row
        }
        let replacement = rebuilt.joined(separator: "\n")
        guard replacement != body else { return nil }
        return SourceReplacement(
            range: SourceRange(location: lines.location, length: (body as NSString).length),
            text: replacement,
            selection: SourceRange(location: lines.location, length: (replacement as NSString).length)
        )
    }

    public static func joinLines(in text: String, selection: SourceRange) -> SourceReplacement? {
        let ns = text as NSString
        guard let lines = coveringLines(ns, selection) else { return nil }
        let body = ns.substring(with: lines)
        guard body.contains("\n") else { return nil }
        let joined = body.replacingOccurrences(of: "\n", with: " ")
        return SourceReplacement(
            range: SourceRange(location: lines.location, length: (body as NSString).length),
            text: joined,
            selection: SourceRange(location: lines.location, length: (joined as NSString).length)
        )
    }

    public static func sortLines(in text: String, selection: SourceRange) -> SourceReplacement? {
        let ns = text as NSString
        guard let lines = coveringLines(ns, selection) else { return nil }
        let body = ns.substring(with: lines)
        var rows = body.components(separatedBy: "\n")
        let trailingBreak = body.hasSuffix("\n") || body.hasSuffix("\r")
        if trailingBreak, rows.last?.isEmpty == true {
            rows.removeLast()
        }
        guard rows.count > 1 else { return nil }
        let sorted = rows.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard sorted != rows else { return nil }
        var replacement = sorted.joined(separator: "\n")
        if trailingBreak { replacement += "\n" }
        return SourceReplacement(
            range: SourceRange(location: lines.location, length: (body as NSString).length),
            text: replacement,
            selection: SourceRange(location: lines.location, length: (replacement as NSString).length)
        )
    }

    public static func trimTrailingWhitespace(in text: String, selection: SourceRange) -> SourceReplacement? {
        let ns = text as NSString
        guard let lines = coveringLines(ns, selection) else { return nil }
        let body = ns.substring(with: lines)
        let rows = body.components(separatedBy: "\n").map { $0.trimmingTrailingWhitespace() }
        let replacement = rows.joined(separator: "\n")
        guard replacement != body else { return nil }
        return SourceReplacement(
            range: SourceRange(location: lines.location, length: (body as NSString).length),
            text: replacement,
            selection: SourceRange(location: lines.location, length: (replacement as NSString).length)
        )
    }

    public static func transformCase(in text: String, selection: SourceRange, style: TextCase) -> SourceReplacement? {
        let ns = text as NSString
        guard selection.length > 0, selection.location >= 0, selection.end <= ns.length else { return nil }
        let selected = ns.substring(with: NSRange(location: selection.location, length: selection.length))
        let replaced: String
        switch style {
        case .upper: replaced = selected.uppercased()
        case .lower: replaced = selected.lowercased()
        case .title: replaced = selected.localizedCapitalized
        }
        guard replaced != selected else { return nil }
        return SourceReplacement(
            range: selection,
            text: replaced,
            selection: SourceRange(location: selection.location, length: (replaced as NSString).length)
        )
    }

    /// Closing marker for languages whose comment is not a bare line prefix.
    public static func lineCommentSuffix(for language: SyntaxLanguage) -> String {
        switch language {
        case .html, .xml:
            return " -->"
        default:
            return ""
        }
    }

    /// Line comment marker for a language. Plain text and Markdown have none.
    public static func lineComment(for language: SyntaxLanguage) -> String? {
        switch language {
        case .python, .shell, .ruby, .yaml, .toml, .ini, .log:
            return "# "
        case .sql:
            return "-- "
        case .html, .xml:
            return "<!-- "
        case .plain, .markdown, .csv, .json, .css:
            // JSON and CSS have no line comment. Commenting one with `//` would
            // write a file the parser rejects, so the command is disabled instead.
            return nil
        default:
            return "// "
        }
    }

    private static func coveringLines(_ ns: NSString, _ selection: SourceRange) -> NSRange? {
        guard selection.location >= 0, selection.location <= ns.length else { return nil }
        let start = min(selection.location, ns.length)
        let end = min(max(start, selection.end), ns.length)
        let origin = ns.length == 0 ? 0 : min(start, max(ns.length - 1, 0))
        var lines = ns.lineRange(for: NSRange(location: origin, length: 0))
        if end > NSMaxRange(lines), end > start {
            let tail = ns.lineRange(for: NSRange(location: min(end - 1, max(ns.length - 1, 0)), length: 0))
            lines = NSUnionRange(lines, tail)
        }
        return lines
    }

    private static func leadingIndent(_ row: String) -> String {
        var indent = ""
        for character in row {
            if character == " " || character == "\t" {
                indent.append(character)
            } else {
                break
            }
        }
        return indent
    }

    private static func hasComment(_ row: String, prefix: String, suffix: String) -> Bool {
        let indent = leadingIndent(row)
        let rest = row.dropFirst(indent.count)
        guard rest.hasPrefix(prefix) else { return false }
        if suffix.isEmpty { return true }
        return rest.count >= prefix.count + suffix.count && rest.hasSuffix(suffix)
    }

    private static func removingComment(_ row: String, prefix: String, suffix: String) -> String {
        let indent = leadingIndent(row)
        var rest = String(row.dropFirst(indent.count))
        if rest.hasPrefix(prefix) {
            rest.removeFirst(prefix.count)
        }
        if !suffix.isEmpty, rest.hasSuffix(suffix), rest.count >= suffix.count {
            rest.removeLast(suffix.count)
        }
        return indent + rest
    }

    private static func removeIndent(_ row: String) -> String {
        if row.hasPrefix("    ") { return String(row.dropFirst(4)) }
        if row.hasPrefix("\t") { return String(row.dropFirst()) }
        var dropped = 0
        var index = row.startIndex
        while dropped < 4, index < row.endIndex, row[index] == " " {
            index = row.index(after: index)
            dropped += 1
        }
        return String(row[index...])
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            if self[previous] == " " || self[previous] == "\t" {
                end = previous
            } else {
                break
            }
        }
        return String(self[..<end])
    }
}
