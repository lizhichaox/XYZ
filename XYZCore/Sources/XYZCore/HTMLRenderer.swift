import Foundation
import Markdown

/// Walks a Markdown AST and writes an HTML fragment.
///
/// This type does not parse. Callers pass a ``Document`` from ``MarkdownParser``.
/// Raw HTML in the source is escaped, and link or image URLs with unsafe schemes are dropped,
/// so a preview of an untrusted file cannot inject script into the web view.
struct HTMLRenderer {
    func render(_ document: Document, reserve: Int = 0) -> String {
        var walker = HTMLRenderingWalker()
        if reserve > 0 {
            walker.html.reserveCapacity(reserve)
        }
        walker.visit(document)
        return walker.html
    }
}

private struct HTMLRenderingWalker: MarkupWalker {
    var html = ""
    private var alignments: [Table.ColumnAlignment?] = []
    private var inHeader = false
    private var anchors = HeadingAnchor.Registry()

    mutating func visitHeading(_ heading: Heading) {
        let level = min(max(heading.level, 1), 6)
        html.append("<h")
        html.append(String(level))
        html.append(" id=\"")
        html.append(HTMLText.attribute(anchors.claim(HeadingAnchor.slug(heading.plainText))))
        html.append("\"")
        html.append(lineMarkup(heading))
        html.append(">")
        descendInto(heading)
        html.append("</h")
        html.append(String(level))
        html.append(">\n")
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        html.append("<p")
        html.append(lineMarkup(paragraph))
        html.append(">")
        descendInto(paragraph)
        html.append("</p>\n")
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        html.append("<blockquote")
        html.append(lineMarkup(blockQuote))
        html.append(">\n")
        descendInto(blockQuote)
        html.append("</blockquote>\n")
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        html.append("<pre")
        html.append(lineMarkup(codeBlock))
        html.append("><code")
        if let language = Self.languageToken(codeBlock.language) {
            html.append(" class=\"language-")
            html.append(HTMLText.attribute(language))
            html.append("\"")
        }
        html.append(">")
        var code = codeBlock.code
        if code.hasSuffix("\n") {
            code.removeLast()
        }
        html.append(HTMLText.escape(code))
        html.append("</code></pre>\n")
    }

    mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) {
        html.append("<pre class=\"raw-html\"")
        html.append(lineMarkup(htmlBlock))
        html.append(">")
        html.append(HTMLText.escape(htmlBlock.rawHTML))
        html.append("</pre>\n")
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        html.append("<hr")
        html.append(lineMarkup(thematicBreak))
        html.append(">\n")
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        html.append("<ul")
        html.append(lineMarkup(unorderedList))
        html.append(">\n")
        descendInto(unorderedList)
        html.append("</ul>\n")
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        html.append("<ol")
        html.append(lineMarkup(orderedList))
        if orderedList.startIndex != 1 {
            html.append(" start=\"")
            html.append(String(orderedList.startIndex))
            html.append("\"")
        }
        html.append(">\n")
        descendInto(orderedList)
        html.append("</ol>\n")
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            html.append("<li class=\"task\"")
            html.append(lineMarkup(listItem))
            html.append("><input type=\"checkbox\" disabled")
            html.append(checked)
            html.append(">")
            descendInto(listItem)
            html.append("</li>\n")
        } else {
            html.append("<li")
            html.append(lineMarkup(listItem))
            html.append(">")
            descendInto(listItem)
            html.append("</li>\n")
        }
    }

    mutating func visitTable(_ table: Table) {
        let previousAlignments = alignments
        alignments = table.columnAlignments
        html.append("<div class=\"table-wrap\"")
        html.append(lineMarkup(table))
        html.append(">\n<table>\n")
        descendInto(table)
        html.append("</table>\n</div>\n")
        alignments = previousAlignments
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        let wasHeader = inHeader
        inHeader = true
        html.append("<thead>\n<tr>\n")
        descendInto(tableHead)
        html.append("</tr>\n</thead>\n")
        inHeader = wasHeader
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard !tableBody.isEmpty else { return }
        html.append("<tbody>\n")
        descendInto(tableBody)
        html.append("</tbody>\n")
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        html.append("<tr")
        html.append(lineMarkup(tableRow))
        html.append(">\n")
        descendInto(tableRow)
        html.append("</tr>\n")
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }
        let tag = inHeader ? "th" : "td"
        html.append("<")
        html.append(tag)
        let index = tableCell.indexInParent
        if index >= 0, index < alignments.count {
            html.append(Self.alignmentAttribute(alignments[index]))
        }
        if tableCell.colspan > 1 {
            html.append(" colspan=\"")
            html.append(String(tableCell.colspan))
            html.append("\"")
        }
        if tableCell.rowspan > 1 {
            html.append(" rowspan=\"")
            html.append(String(tableCell.rowspan))
            html.append("\"")
        }
        html.append(">")
        descendInto(tableCell)
        html.append("</")
        html.append(tag)
        html.append(">\n")
    }

    mutating func visitText(_ text: Text) {
        html.append(HTMLText.escape(text.string))
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        html.append("\n")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        html.append("<br>\n")
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        html.append("<em>")
        descendInto(emphasis)
        html.append("</em>")
    }

    mutating func visitStrong(_ strong: Strong) {
        html.append("<strong>")
        descendInto(strong)
        html.append("</strong>")
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        html.append("<del>")
        descendInto(strikethrough)
        html.append("</del>")
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        html.append("<code>")
        html.append(HTMLText.escape(inlineCode.code))
        html.append("</code>")
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        html.append(HTMLText.escape(inlineHTML.rawHTML))
    }

    mutating func visitLink(_ link: Link) {
        guard let destination = URLPolicy.linkDestination(link.destination) else {
            descendInto(link)
            return
        }
        html.append("<a href=\"")
        html.append(HTMLText.attribute(destination))
        html.append("\"")
        if let title = link.title, !title.isEmpty {
            html.append(" title=\"")
            html.append(HTMLText.attribute(title))
            html.append("\"")
        }
        html.append(">")
        descendInto(link)
        html.append("</a>")
    }

    mutating func visitImage(_ image: Image) {
        let alt = HTMLText.attribute(Self.plainText(image))
        guard let source = URLPolicy.imageSource(image.source) else {
            html.append(HTMLText.escape(Self.plainText(image)))
            return
        }
        html.append("<img alt=\"")
        html.append(alt)
        html.append("\" src=\"")
        html.append(HTMLText.attribute(source))
        html.append("\"")
        if let title = image.title, !title.isEmpty {
            html.append(" title=\"")
            html.append(HTMLText.attribute(title))
            html.append("\"")
        }
        html.append(">")
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        html.append("<code>")
        html.append(HTMLText.escape(symbolLink.destination ?? ""))
        html.append("</code>")
    }

    /// `data-line` / `data-end` are 1-based source lines. `data-end` is inclusive.
    /// The type is spelled out so it cannot be confused with XYZCore's edit range.
    private func lineMarkup(_ markup: Markup) -> String {
        guard let range: Range<SourceLocation> = markup.range else { return "" }
        let start = range.lowerBound.line
        guard start > 0 else { return "" }
        let end = max(start, range.upperBound.line)
        return " data-line=\"\(start)\" data-end=\"\(end)\""
    }

    private static func alignmentAttribute(_ alignment: Table.ColumnAlignment?) -> String {
        switch alignment {
        case .left:
            return " style=\"text-align:left\""
        case .center:
            return " style=\"text-align:center\""
        case .right:
            return " style=\"text-align:right\""
        case nil:
            return ""
        }
    }

    private static func languageToken(_ language: String?) -> String? {
        guard let language else { return nil }
        let token = language.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let cleaned = String(token.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func plainText(_ markup: Markup) -> String {
        if let text = markup as? Text {
            return text.string
        }
        if let code = markup as? InlineCode {
            return code.code
        }
        var result = ""
        for index in 0..<markup.childCount {
            guard let child = markup.child(at: index) else { continue }
            if child is SoftBreak || child is LineBreak {
                result.append(" ")
            } else {
                result.append(plainText(child))
            }
        }
        return result
    }
}

/// Heading ids for `#fragment` links, as GitHub writes them: lowercase, spaces to hyphens,
/// punctuation dropped, letters of every script kept. A repeated heading gets `-1`, `-2`, ….
public enum HeadingAnchor {
    public static func slug(_ title: String) -> String {
        var slug = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " || character == "\t" {
                slug.append("-")
            }
        }
        return slug.isEmpty ? "section" : slug
    }

    struct Registry {
        private var used: [String: Int] = [:]

        mutating func claim(_ slug: String) -> String {
            guard let count = used[slug] else {
                used[slug] = 1
                return slug
            }
            var next = count
            var candidate = "\(slug)-\(next)"
            while used[candidate] != nil {
                next += 1
                candidate = "\(slug)-\(next)"
            }
            used[slug] = next + 1
            used[candidate] = 1
            return candidate
        }
    }
}

enum HTMLText {
    static func escape(_ string: String) -> String {
        guard string.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\"" || $0 == "'" }) else {
            return string
        }
        var result = ""
        result.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "&":
                result.append("&amp;")
            case "<":
                result.append("&lt;")
            case ">":
                result.append("&gt;")
            case "\"":
                result.append("&quot;")
            case "'":
                result.append("&#39;")
            default:
                result.append(character)
            }
        }
        return result
    }

    static func attribute(_ string: String) -> String {
        let flattened = string.replacingOccurrences(of: "\n", with: " ")
        return escape(flattened)
    }
}

enum URLPolicy {
    private static let linkSchemes: Set<String> = ["http", "https", "mailto"]
    private static let imageSchemes: Set<String> = ["http", "https"]

    static func linkDestination(_ raw: String?) -> String? {
        sanitize(raw, allowedSchemes: linkSchemes)
    }

    static func imageSource(_ raw: String?) -> String? {
        sanitize(raw, allowedSchemes: imageSchemes)
    }

    private static func sanitize(_ raw: String?, allowedSchemes: Set<String>) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.unicodeScalars.contains(where: { $0.value < 32 }) {
            return nil
        }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("javascript:") || lowered.hasPrefix("vbscript:") || lowered.hasPrefix("data:") {
            return nil
        }
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = String(trimmed[..<colon]).lowercased()
            // Windows-style paths and unknown schemes are rejected. Relative URLs have no scheme.
            if scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }) {
                guard allowedSchemes.contains(scheme) else { return nil }
            }
        }
        return trimmed
    }
}
