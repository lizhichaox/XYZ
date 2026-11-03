import Foundation
import Markdown

/// One heading in a note, for Go to Heading.
public struct OutlineHeading: Equatable, Sendable {
    public var level: Int
    public var title: String
    /// 1-based source line, the same numbering as `data-line` in Reading.
    public var line: Int

    public init(level: Int, title: String, line: Int) {
        self.level = level
        self.title = title
        self.line = line
    }
}

/// The headings of a Markdown note, in order. Uses the same parser as Reading,
/// so a `#` inside a code block or an indented line is not a heading.
public enum MarkdownOutline {
    public static func headings(in markdown: String) -> [OutlineHeading] {
        var walker = OutlineWalker()
        walker.visit(MarkdownParser.parse(markdown))
        return walker.headings
    }
}

private struct OutlineWalker: MarkupWalker {
    var headings: [OutlineHeading] = []

    mutating func visitHeading(_ heading: Heading) {
        let title = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = heading.range?.lowerBound.line ?? 0
        guard !title.isEmpty, line > 0 else { return }
        headings.append(OutlineHeading(level: heading.level, title: title, line: line))
    }
}
