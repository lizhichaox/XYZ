import Foundation

/// Whether Return, Tab, and the Format commands should edit Markdown markers.
public enum TextMarkup {
    /// Untitled documents (no extension yet) are Markdown. `.txt` and other names are not.
    public static func allows(fileExtension: String?) -> Bool {
        switch fileExtension?.lowercased() {
        case nil, "md", "markdown":
            return true
        default:
            return false
        }
    }
}

/// A UTF-16 range, matching `NSTextView` and `UITextView` selections.
public struct SourceRange: Equatable, Sendable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var end: Int { location + length }
}

/// A single undoable replacement. `selection` is measured in the document after `text` is inserted.
public struct SourceReplacement: Equatable, Sendable {
    public var range: SourceRange
    public var text: String
    public var selection: SourceRange

    public init(range: SourceRange, text: String, selection: SourceRange) {
        self.range = range
        self.text = text
        self.selection = selection
    }
}

/// Markdown typing behavior that does not depend on AppKit or UIKit.
///
/// Plain-text files should not call these. A line inside a code fence is left alone.
public enum SourceEditing {
    public static func newline(in text: String, selection: SourceRange) -> SourceReplacement? {
        let ns = text as NSString
        guard selection.length == 0, contains(selection, length: ns.length) else { return nil }
        let line = lineRange(in: ns, at: selection.location)
        guard !insideFence(ns, before: line.location) else { return nil }
        let parts = split(ns, line)
        let content = ns.substring(with: parts.content) as NSString
        guard let marker = marker(in: content) else { return nil }
        let markerEnd = parts.content.location + marker.indentUTF16 + marker.prefixUTF16
        guard selection.location >= markerEnd else { return nil }
        let body = content.substring(from: marker.indentUTF16 + marker.prefixUTF16)
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return closeEmptyItem(ns: ns, content: parts.content, marker: marker, caret: selection.location)
        }
        let indent = content.substring(with: NSRange(location: 0, length: marker.indentUTF16))
        var replaced = 0
        if selection.location < ns.length, ns.character(at: selection.location) == 0x20 {
            replaced = 1
        }
        let insertion = "\n" + indent + marker.continued
        let inserted = (insertion as NSString).length
        return SourceReplacement(
            range: SourceRange(location: selection.location, length: replaced),
            text: insertion,
            selection: SourceRange(location: selection.location + inserted, length: 0)
        )
    }

    public static func indent(in text: String, selection: SourceRange) -> SourceReplacement? {
        shift(in: text, selection: selection, inserting: true)
    }

    public static func outdent(in text: String, selection: SourceRange) -> SourceReplacement? {
        shift(in: text, selection: selection, inserting: false)
    }

    public static func toggleBold(in text: String, selection: SourceRange) -> SourceReplacement? {
        toggle(marker: "**", in: text, selection: selection)
    }

    public static func toggleItalic(in text: String, selection: SourceRange) -> SourceReplacement? {
        toggle(marker: "*", in: text, selection: selection)
    }

    public static func toggleStrikethrough(in text: String, selection: SourceRange) -> SourceReplacement? {
        toggle(marker: "~~", in: text, selection: selection)
    }

    public static func toggleInlineCode(in text: String, selection: SourceRange) -> SourceReplacement? {
        toggle(marker: "`", in: text, selection: selection)
    }

    private static func closeEmptyItem(
        ns: NSString,
        content: NSRange,
        marker: Marker,
        caret: Int
    ) -> SourceReplacement? {
        let indentRange = NSRange(location: content.location, length: marker.indentUTF16)
        let indent = ns.substring(with: indentRange)
        if let shorter = droppedIndent(indent) {
            let delta = (indent as NSString).length - (shorter as NSString).length
            return SourceReplacement(
                range: SourceRange(location: indentRange.location, length: indentRange.length),
                text: shorter,
                selection: SourceRange(location: max(content.location, caret - delta), length: 0)
            )
        }
        let prefixLength = marker.prefixUTF16
        let start = content.location + marker.indentUTF16
        return SourceReplacement(
            range: SourceRange(location: start, length: prefixLength),
            text: "",
            selection: SourceRange(location: start, length: 0)
        )
    }

    private static func shift(in text: String, selection: SourceRange, inserting: Bool) -> SourceReplacement? {
        let ns = text as NSString
        guard contains(selection, length: ns.length) else { return nil }
        let span = coveringLines(in: ns, selection: selection)
        guard !insideFence(ns, before: span.location) else { return nil }
        var rebuilt = ""
        var sawList = false
        var changed = false
        var locationShift = 0
        var lengthShift = 0
        var cursor = span.location
        let spanEnd = NSMaxRange(span)
        while cursor < spanEnd || (cursor == span.location && span.length == 0) {
            let line = lineRange(in: ns, at: min(cursor, max(ns.length, 0)))
            if line.length == 0, cursor >= spanEnd { break }
            let parts = split(ns, line)
            let content = ns.substring(with: parts.content) as NSString
            if marker(in: content) != nil { sawList = true }
            let removed = inserting ? 0 : removableIndent(content)
            if inserting {
                rebuilt += "  "
                rebuilt += content as String
                changed = true
            } else if removed > 0 {
                rebuilt += content.substring(from: removed)
                changed = true
            } else {
                rebuilt += content as String
            }
            rebuilt += ns.substring(with: parts.newline)
            let delta = inserting ? 2 : -removed
            if line.location <= selection.location {
                locationShift += delta
            } else if line.location <= selection.end {
                lengthShift += delta
            }
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
            if span.length == 0 { break }
        }
        guard sawList, changed else { return nil }
        let nextLocation = max(0, selection.location + locationShift)
        let nextLength = max(0, selection.length + lengthShift)
        return SourceReplacement(
            range: SourceRange(location: span.location, length: span.length),
            text: rebuilt,
            selection: SourceRange(location: nextLocation, length: nextLength)
        )
    }

    private static func toggle(marker: String, in text: String, selection: SourceRange) -> SourceReplacement? {
        let ns = text as NSString
        guard contains(selection, length: ns.length) else { return nil }
        let markerLength = (marker as NSString).length
        if let wrapped = unwrap(marker: marker, markerLength: markerLength, ns: ns, selection: selection) {
            return wrapped
        }
        let selected = ns.substring(with: NSRange(location: selection.location, length: selection.length))
        let wrapped = marker + selected + marker
        return SourceReplacement(
            range: selection,
            text: wrapped,
            selection: SourceRange(location: selection.location + markerLength, length: selection.length)
        )
    }

    private static func unwrap(
        marker: String,
        markerLength: Int,
        ns: NSString,
        selection: SourceRange
    ) -> SourceReplacement? {
        if let outer = outerWrap(marker: marker, markerLength: markerLength, ns: ns, selection: selection) {
            return outer
        }
        let selected = ns.substring(with: NSRange(location: selection.location, length: selection.length))
        guard selected.utf16.count >= markerLength * 2 else { return nil }
        guard selected.hasPrefix(marker), selected.hasSuffix(marker) else { return nil }
        if marker == "*", (selected.hasPrefix("**") || selected.hasSuffix("**")) {
            return nil
        }
        let innerLength = selection.length - markerLength * 2
        let inner = (selected as NSString).substring(with: NSRange(location: markerLength, length: innerLength))
        return SourceReplacement(
            range: selection,
            text: inner,
            selection: SourceRange(location: selection.location, length: innerLength)
        )
    }

    private static func outerWrap(
        marker: String,
        markerLength: Int,
        ns: NSString,
        selection: SourceRange
    ) -> SourceReplacement? {
        guard selection.location >= markerLength else { return nil }
        guard selection.end + markerLength <= ns.length else { return nil }
        let before = ns.substring(with: NSRange(location: selection.location - markerLength, length: markerLength))
        let after = ns.substring(with: NSRange(location: selection.end, length: markerLength))
        guard before == marker, after == marker else { return nil }
        if marker == "*" {
            if selection.location - markerLength > 0, ns.character(at: selection.location - markerLength - 1) == 0x2A {
                return nil
            }
            if selection.end + markerLength < ns.length, ns.character(at: selection.end + markerLength) == 0x2A {
                return nil
            }
        }
        let inner = ns.substring(with: NSRange(location: selection.location, length: selection.length))
        return SourceReplacement(
            range: SourceRange(location: selection.location - markerLength, length: selection.length + markerLength * 2),
            text: inner,
            selection: SourceRange(location: selection.location - markerLength, length: selection.length)
        )
    }

    private struct Marker {
        var indentUTF16: Int
        var prefixUTF16: Int
        var continued: String
    }

    private static func marker(in content: NSString) -> Marker? {
        let length = content.length
        var index = 0
        while index < length {
            let character = content.character(at: index)
            if character == 0x20 || character == 0x09 {
                index += 1
            } else {
                break
            }
        }
        let indent = index
        guard index < length else { return nil }
        let bullet = content.character(at: index)
        if bullet == 0x2D || bullet == 0x2A || bullet == 0x2B {
            return bulletMarker(content, indent: indent, bulletAt: index)
        }
        if bullet >= 0x30, bullet <= 0x39 {
            return orderedMarker(content, indent: indent, digitsAt: index)
        }
        return nil
    }

    private static func bulletMarker(_ content: NSString, indent: Int, bulletAt: Int) -> Marker? {
        let length = content.length
        let next = bulletAt + 1
        guard next < length else { return nil }
        let gap = content.character(at: next)
        guard gap == 0x20 || gap == 0x09 else { return nil }
        var cursor = next
        while cursor < length {
            let character = content.character(at: cursor)
            if character == 0x20 || character == 0x09 {
                cursor += 1
            } else {
                break
            }
        }
        let bullet = content.substring(with: NSRange(location: bulletAt, length: 1))
        if cursor + 2 < length,
           content.character(at: cursor) == 0x5B,
           isCheckbox(content.character(at: cursor + 1)),
           content.character(at: cursor + 2) == 0x5D {
            var end = cursor + 3
            if end < length {
                let after = content.character(at: end)
                if after == 0x20 || after == 0x09 {
                    end += 1
                }
            }
            return Marker(
                indentUTF16: indent,
                prefixUTF16: end - bulletAt,
                continued: bullet + " [ ] "
            )
        }
        if cursor == length, next + 1 == length {
            return Marker(indentUTF16: indent, prefixUTF16: 2, continued: bullet + " ")
        }
        let prefixEnd = next + 1
        return Marker(indentUTF16: indent, prefixUTF16: prefixEnd - bulletAt, continued: bullet + " ")
    }

    private static func orderedMarker(_ content: NSString, indent: Int, digitsAt: Int) -> Marker? {
        let length = content.length
        var cursor = digitsAt
        var digits = 0
        while cursor < length, digits < 9 {
            let character = content.character(at: cursor)
            if character < 0x30 || character > 0x39 { break }
            digits += 1
            cursor += 1
        }
        guard digits > 0, cursor < length else { return nil }
        let punct = content.character(at: cursor)
        guard punct == 0x2E || punct == 0x29 else { return nil }
        let gap = cursor + 1
        guard gap < length else { return nil }
        let space = content.character(at: gap)
        guard space == 0x20 || space == 0x09 else { return nil }
        let numberText = content.substring(with: NSRange(location: digitsAt, length: digits))
        let number = Int(numberText) ?? 0
        let next = String(format: "%0\(digits)d", number + 1)
        let punctText = punct == 0x2E ? "." : ")"
        let gapText = space == 0x09 ? "\t" : " "
        return Marker(
            indentUTF16: indent,
            prefixUTF16: gap + 1 - digitsAt,
            continued: next + punctText + gapText
        )
    }

    private static func isCheckbox(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x78 || character == 0x58
    }

    private static func droppedIndent(_ indent: String) -> String? {
        if indent.hasSuffix("\t") {
            return String(indent.dropLast())
        }
        if indent.hasSuffix("  ") {
            return String(indent.dropLast(2))
        }
        if indent.hasSuffix(" ") {
            return String(indent.dropLast())
        }
        return nil
    }

    private static func removableIndent(_ content: NSString) -> Int {
        guard content.length > 0 else { return 0 }
        if content.character(at: 0) == 0x09 { return 1 }
        if content.length >= 2, content.character(at: 0) == 0x20, content.character(at: 1) == 0x20 {
            return 2
        }
        if content.character(at: 0) == 0x20 { return 1 }
        return 0
    }

    static func insideFence(_ ns: NSString, before location: Int) -> Bool {
        var cursor = 0
        var open = false
        while cursor < location, cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let parts = split(ns, line)
            if isFence(ns.substring(with: parts.content) as NSString) {
                open.toggle()
            }
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
        }
        return open
    }

    static func isFence(_ content: NSString) -> Bool {
        var index = 0
        var indent = 0
        while index < content.length, indent < 4 {
            let character = content.character(at: index)
            if character == 0x20 || character == 0x09 {
                indent += 1
                index += 1
            } else {
                break
            }
        }
        guard indent <= 3, index < content.length else { return false }
        let marker = content.character(at: index)
        guard marker == 0x60 || marker == 0x7E else { return false }
        var count = 0
        while index < content.length, content.character(at: index) == marker {
            count += 1
            index += 1
        }
        return count >= 3
    }

    static func coveringLines(in ns: NSString, selection: SourceRange) -> NSRange {
        if ns.length == 0 { return NSRange(location: 0, length: 0) }
        let start = lineRange(in: ns, at: selection.location)
        let endLocation = selection.length == 0 ? selection.location : max(selection.location, selection.end - 1)
        let end = lineRange(in: ns, at: endLocation)
        let lower = start.location
        let upper = NSMaxRange(end)
        return NSRange(location: lower, length: upper - lower)
    }

    static func lineRange(in ns: NSString, at location: Int) -> NSRange {
        if ns.length == 0 { return NSRange(location: 0, length: 0) }
        let clamped = min(max(0, location), ns.length)
        let line = ns.lineRange(for: NSRange(location: clamped, length: 0))
        if line.length == 0, clamped == ns.length, clamped > 0 {
            let previous = ns.character(at: clamped - 1)
            if previous != 0x0A, previous != 0x0D {
                return ns.lineRange(for: NSRange(location: clamped - 1, length: 0))
            }
        }
        return line
    }

    static func split(_ ns: NSString, _ range: NSRange) -> (content: NSRange, newline: NSRange) {
        var content = range
        if content.length == 0 {
            return (content, NSRange(location: range.location, length: 0))
        }
        let last = ns.character(at: NSMaxRange(content) - 1)
        if last == 0x0A {
            content.length -= 1
            if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 0x0D {
                content.length -= 1
            }
        } else if last == 0x0D {
            content.length -= 1
        }
        let newline = NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))
        return (content, newline)
    }

    static func contains(_ selection: SourceRange, length: Int) -> Bool {
        selection.location >= 0
            && selection.length >= 0
            && selection.end <= length
    }
}
