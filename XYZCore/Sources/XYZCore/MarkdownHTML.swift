import Foundation

/// Public entry point from Markdown source to an HTML fragment.
///
/// The fragment is the document body only (no `<html>` shell). The app wraps it in the
/// preview page and swaps it into the web view without reloading.
public enum MarkdownHTML: Sendable {
    public static func render(_ markdown: String) -> String {
        let prepared = ReadingSource.prepare(markdown)
        let document = MarkdownParser.parse(prepared.body)
        let body = HTMLRenderer().render(document, reserve: markdown.utf8.count + 64)
        let properties = prepared.properties.html
        if properties.isEmpty { return body }
        return properties + body
    }
}
