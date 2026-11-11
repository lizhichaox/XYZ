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
        let prepared = ReadingSource.prepareForReading(markdown)
        let body = renderBody(
            prepared.body,
            allowRemoteImages: allowRemoteImages,
            allowsTaskToggle: allowsTaskToggle,
            includesLineNumbers: true,
            reserve: markdown.utf8.count + 64
        )
        let withFootnotes = FootnoteHTML.attach(
            body,
            footnotes: prepared.footnotes,
            allowRemoteImages: allowRemoteImages
        )
        let properties = prepared.properties.html
        if properties.isEmpty { return withFootnotes }
        return properties + withFootnotes
    }

    /// Renders prepared Markdown. Footnote definitions use it: they are a footer, so they
    /// carry no source-line attributes.
    static func renderBody(
        _ markdown: String,
        allowRemoteImages: Bool,
        allowsTaskToggle: Bool,
        includesLineNumbers: Bool,
        reserve: Int = 0
    ) -> String {
        let document = MarkdownParser.parse(markdown)
        let body = HTMLRenderer(
            allowsRemoteImages: allowRemoteImages,
            allowsTaskToggle: allowsTaskToggle,
            includesLineNumbers: includesLineNumbers
        )
        .render(document, reserve: reserve)
        return BlockID.rewrite(body)
    }

    /// A footnote definition's own Markdown: comments and wiki links are prepared, but a
    /// nested footnote reference stays literal.
    static func renderDefinition(_ markdown: String, allowRemoteImages: Bool) -> String {
        let prepared = ReadingSource.prepare(markdown)
        return renderBody(
            prepared.body,
            allowRemoteImages: allowRemoteImages,
            allowsTaskToggle: false,
            includesLineNumbers: false
        )
    }
}
