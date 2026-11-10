import Foundation

/// Public entry point from Markdown source to an HTML fragment.
///
/// The fragment is the document body only (no `<html>` shell). The app wraps it in the
/// preview page and swaps it into the web view without reloading.
public enum MarkdownHTML: Sendable {
    /// `allowRemoteImages` is off when Reading should not contact another server; a
    /// picture at an `http` or `https` URL then shows as its alt text. A picture next
    /// to the note is a relative URL and is always rendered.
    public static func render(
        _ markdown: String,
        allowRemoteImages: Bool = true,
        allowsTaskToggle: Bool = true
    ) -> String {
        let prepared = ReadingSource.prepare(markdown)
        let document = MarkdownParser.parse(prepared.body)
        let body = HTMLRenderer(
            allowsRemoteImages: allowRemoteImages,
            allowsTaskToggle: allowsTaskToggle
        )
        .render(document, reserve: markdown.utf8.count + 64)
        let withBlockIDs = BlockID.rewrite(body)
        let properties = prepared.properties.html
        if properties.isEmpty { return withBlockIDs }
        return properties + withBlockIDs
    }
}
