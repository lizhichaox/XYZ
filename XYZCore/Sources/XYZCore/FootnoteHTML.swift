import Foundation

/// Footnote references and the footer section.
///
/// `ReadingSource` replaces each `[^id]` reference with a private-use placeholder and
/// removes the definitions from the body. This pass turns the placeholders into
/// superscript links and appends the numbered definitions.
enum FootnoteHTML {
    /// Removes the private-use placeholders from a string, for a heading slug or an
    /// outline title.
    static func removingPlaceholders(_ text: String) -> String {
        guard text.contains("\u{E000}") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "\u{E000}[0-9]+\u{E001}") else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: ""
        )
    }

    static func attach(
        _ html: String,
        footnotes: ReadingSource.Footnotes,
        allowRemoteImages: Bool
    ) -> String {
        guard !footnotes.isEmpty else { return html }
        return replaceReferences(html, footnotes: footnotes)
            + section(footnotes, allowRemoteImages: allowRemoteImages)
    }

    private static func replaceReferences(
        _ html: String,
        footnotes: ReadingSource.Footnotes
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{E000}([0-9]+)\u{E001}") else {
            return html
        }
        let ns = html as NSString
        var result = ""
        result.reserveCapacity(ns.length + 64)
        var cursor = 0
        var seen: Set<Int> = []
        for match in regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let ordinal = Int(ns.substring(with: match.range(at: 1))) ?? 0
            if ordinal >= 1, ordinal <= footnotes.numbers.count {
                let number = footnotes.numbers[ordinal - 1]
                let first = seen.insert(number).inserted
                result += "<sup class=\"footnote-ref\""
                if first { result += " id=\"fnref-\(number)\"" }
                result += "><a href=\"#fn-\(number)\">\(number)</a></sup>"
            }
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func section(
        _ footnotes: ReadingSource.Footnotes,
        allowRemoteImages: Bool
    ) -> String {
        var result = "<section class=\"footnotes\">\n<hr>\n<ol>\n"
        for (index, id) in footnotes.order.enumerated() {
            let number = index + 1
            let markdown = footnotes.definitions[id] ?? ""
            result += "<li id=\"fn-\(number)\">"
            result += MarkdownHTML.renderDefinition(markdown, allowRemoteImages: allowRemoteImages)
            result += "<a class=\"footnote-backref\" href=\"#fnref-\(number)\" aria-label=\"Back to reference\">↩</a>"
            result += "</li>\n"
        }
        result += "</ol>\n</section>\n"
        return result
    }
}
