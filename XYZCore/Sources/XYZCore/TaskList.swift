import Foundation

/// Toggles a GFM task-list checkbox in the source text.
///
/// Reading renders task items as checkboxes. A click posts the item's source line, and
/// this type changes the `[ ]` / `[x]` marker on that line without touching the rest of
/// the document. The line number is the same one the renderer puts on the list item.
public enum TaskList {
    public struct Toggle: Equatable, Sendable {
        public var text: String
        public var line: Int
        public var isChecked: Bool

        public init(text: String, line: Int, isChecked: Bool) {
            self.text = text
            self.line = line
            self.isChecked = isChecked
        }
    }

    /// Returns the document with the task marker on `line` flipped, or nil when the line
    /// is not a task item.
    public static func toggle(in text: String, line: Int) -> Toggle? {
        guard line > 0 else { return nil }
        let ns = text as NSString
        var location = 0
        var current = 1
        while current < line {
            guard location < ns.length else { return nil }
            location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        guard location < ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        var content = lineRange
        while content.length > 0 {
            let last = ns.character(at: NSMaxRange(content) - 1)
            if last == 0x0A || last == 0x0D {
                content.length -= 1
            } else {
                break
            }
        }
        let lineText = ns.substring(with: content)
        guard let marker = markerRange(in: lineText) else { return nil }
        let wasChecked = ns.substring(with: marker) != " "
        let updatedLine = (lineText as NSString).replacingCharacters(in: marker, with: wasChecked ? " " : "x")
        let updated = ns.replacingCharacters(in: content, with: updatedLine)
        return Toggle(text: updated, line: line, isChecked: !wasChecked)
    }

    /// The state character inside `[ ]`, `[x]`, or `[X]`, after a list marker.
    private static func markerRange(in line: String) -> NSRange? {
        guard let regex = markerRegex else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }
        return match.range(at: 1)
    }

    private static let markerRegex = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]?)*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+\[([ xX])\]"#
    )
}
