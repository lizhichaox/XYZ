import Foundation

/// Obsidian block IDs: a trailing `^id` on a paragraph or list item. Reading hides the
/// marker and gives the block an anchor so `[[#^id]]` can scroll to it.
enum BlockID {
    static func rewrite(_ html: String) -> String {
        guard html.contains("^") else { return html }
        return rewrite(rewrite(html, with: paragraphRegex), with: listItemRegex)
    }

    private static func rewrite(_ html: String, with regex: NSRegularExpression?) -> String {
        guard let regex else { return html }
        let ns = html as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let tag = ns.substring(with: match.range(at: 1))
            let attributes = ns.substring(with: match.range(at: 2))
            let body = ns.substring(with: match.range(at: 3))
            let id = ns.substring(with: match.range(at: 4))
            result += "<\(tag)\(attributes) id=\"\(id)\">\(body)</\(tag)>"
            cursor = NSMaxRange(match.range)
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static let paragraphRegex = try? NSRegularExpression(
        pattern: #"<(p)([^>]*)>((?:(?!</p>).)*?)\s*\^([A-Za-z0-9-]+)\s*</p>"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let listItemRegex = try? NSRegularExpression(
        pattern: #"<(li)([^>]*)>((?:(?!</li>).)*?)\s*\^([A-Za-z0-9-]+)\s*</li>"#,
        options: [.dotMatchesLineSeparators]
    )
}
