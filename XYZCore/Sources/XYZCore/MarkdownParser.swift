import Markdown

/// Parses Markdown into a swift-markdown AST.
///
/// Rendering is intentionally not done here. GFM tables, strikethrough, and task lists
/// are enabled by swift-markdown's cmark-gfm parser. Smart punctuation is off so the
/// preview stays faithful to the characters in the file. Source positions stay on:
/// each block's `range` is the line number Reading uses to return to the same place.
enum MarkdownParser {
    static func parse(_ source: String) -> Document {
        Document(
            parsing: source,
            options: [.disableSmartOpts]
        )
    }
}
