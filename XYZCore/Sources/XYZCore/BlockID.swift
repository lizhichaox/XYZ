import Foundation

/// Obsidian block IDs: a trailing `^id` on a paragraph, list item, or heading. Reading
/// hides the marker and gives the block an anchor so `[[#^id]]` can scroll to it.
enum BlockID {
    static func rewrite(_ html: String) -> String {
        guard html.contains("^"), let regex = regex else { return html }
        let range = NSRange(location: 0, length: (html as NSString).length)
        return regex.stringByReplacingMatches(
            in: html,
            options: [],
            range: range,
            withTemplate: " id=\"$1\"></$2>"
        )
    }

    private static let regex = try? NSRegularExpression(
        pattern: #"\s*\^([A-Za-z0-9-]+)\s*</(p|li|h[1-6])>"#
    )
}
