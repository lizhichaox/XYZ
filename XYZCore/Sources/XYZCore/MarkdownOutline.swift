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

/// The headings of a Markdown note, in order. Uses the same parser and the same
/// preparation as Reading, so a `#` inside a code block or an indented line is not a
/// heading, front matter is not scanned, and a wiki link reads as the text Reading shows.
public enum MarkdownOutline {
    public static func headings(in markdown: String) -> [OutlineHeading] {
        // Front matter is masked with spaces and wiki links become ordinary links, so
        // `heading.range.line` still counts the file's own lines. Parsing the raw text
        // instead turned a `# comment` in YAML into a heading and listed `[[Page]]` as
        // literal brackets while the page showed a link.
        let prepared = ReadingSource.prepareForReading(markdown)
        var walker = OutlineWalker()
        walker.visit(MarkdownParser.parse(prepared.body))
        return walker.headings
    }
}

private struct OutlineWalker: MarkupWalker {
    var headings: [OutlineHeading] = []

    mutating func visitHeading(_ heading: Heading) {
        let title = FootnoteHTML.removingPlaceholders(heading.plainText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let line = heading.range?.lowerBound.line ?? 0
        guard !title.isEmpty, line > 0 else { return }
        headings.append(OutlineHeading(level: heading.level, title: title, line: line))
    }
}
