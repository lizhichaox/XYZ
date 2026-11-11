import Foundation

/// Front matter and wiki links, prepared before the Markdown parser runs.
///
/// Line breaks are kept, so a heading's source line number does not move. Wiki links
/// inside fenced or inline code are left as typed.
enum ReadingSource {
    struct Properties {
        var pairs: [(key: String, value: String)] = []

        var html: String {
            guard !pairs.isEmpty else { return "" }
            var result = "<dl class=\"properties\">\n"
            for pair in pairs {
                result.append("<dt>")
                result.append(HTMLText.escape(pair.key))
                result.append("</dt><dd>")
                result.append(HTMLText.escape(pair.value))
                result.append("</dd>\n")
            }
            result.append("</dl>\n")
            return result
        }
    }

    static func prepare(_ source: String) -> (body: String, properties: Properties) {
        var properties = Properties()
        let masked = maskFrontMatter(source, into: &properties) ?? source
        return (rewriteWikiLinks(maskComments(masked)), properties)
    }

    /// Footnotes: definitions removed from the body, references replaced by placeholders.
    struct Footnotes {
        /// Definition Markdown by id.
        var definitions: [String: String] = [:]
        /// Ids in first-reference order; the footnote number is the index plus one.
        var order: [String] = []
        /// The id each placeholder stands for, in document order.
        var references: [String] = []
        /// The footnote number for each reference, shared by repeated references.
        var numbers: [Int] = []

        var isEmpty: Bool { order.isEmpty }
    }

    /// The same preparation as `prepare`, plus footnote extraction and reference rewriting.
    static func prepareForReading(_ source: String) -> (body: String, properties: Properties, footnotes: Footnotes) {
        var properties = Properties()
        let masked = maskFrontMatter(source, into: &properties) ?? source
        let commented = maskComments(masked)
        let extracted = extractFootnotes(commented)
        let linked = rewriteWikiLinks(extracted.body)
        let referenced = rewriteFootnoteReferences(linked, definitions: extracted.definitions)
        var footnotes = Footnotes()
        footnotes.definitions = extracted.definitions
        footnotes.order = referenced.order
        footnotes.references = referenced.references
        footnotes.numbers = referenced.numbers
        return (referenced.body, properties, footnotes)
    }

    /// Removes `[^id]: text` definitions (and their indented continuation lines) from the
    /// body, leaving blank lines so every later source line keeps its number.
    private static func extractFootnotes(_ source: String) -> (body: String, definitions: [String: String]) {
        guard source.contains("[^") else { return (source, [:]) }
        let ns = source as NSString
        var result = ""
        result.reserveCapacity(ns.length)
        var definitions: [String: String] = [:]
        var inFence = false
        var cursor = 0
        var pendingID: String?
        var pendingLines: [String] = []
        func flush() {
            guard let id = pendingID else { return }
            if definitions[id] == nil {
                definitions[id] = pendingLines.joined(separator: "\n")
            }
            pendingID = nil
            pendingLines = []
        }
        while cursor < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inFence, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                inFence.toggle()
                result.append(line)
                cursor = NSMaxRange(lineRange)
                continue
            }
            if inFence {
                flush()
                result.append(line)
                cursor = NSMaxRange(lineRange)
                continue
            }
            if let definition = footnoteDefinition(line) {
                flush()
                pendingID = definition.id
                pendingLines = [definition.content]
                result.append(blankLine(line))
                cursor = NSMaxRange(lineRange)
                continue
            }
            if pendingID != nil, let continuation = footnoteContinuation(line) {
                pendingLines.append(continuation)
                result.append(blankLine(line))
                cursor = NSMaxRange(lineRange)
                continue
            }
            flush()
            result.append(line)
            cursor = NSMaxRange(lineRange)
        }
        flush()
        return (result, definitions)
    }

    /// `[^id]: text` with up to three leading spaces.
    private static func footnoteDefinition(_ line: String) -> (id: String, content: String)? {
        var text = line
        if text.hasSuffix("\n") { text.removeLast() }
        if text.hasSuffix("\r") { text.removeLast() }
        var index = text.startIndex
        var spaces = 0
        while index < text.endIndex, text[index] == " " {
            spaces += 1
            if spaces > 3 { return nil }
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "[" else { return nil }
        index = text.index(after: index)
        guard index < text.endIndex, text[index] == "^" else { return nil }
        index = text.index(after: index)
        let idStart = index
        while index < text.endIndex, text[index] != "]" {
            if text[index].isWhitespace { return nil }
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "]" else { return nil }
        let id = String(text[idStart..<index])
        guard !id.isEmpty else { return nil }
        index = text.index(after: index)
        guard index < text.endIndex, text[index] == ":" else { return nil }
        index = text.index(after: index)
        if index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }
        return (id, String(text[index...]))
    }

    /// A definition's continuation line: indented four spaces or one tab.
    private static func footnoteContinuation(_ line: String) -> String? {
        var text = line
        if text.hasSuffix("\n") { text.removeLast() }
        if text.hasSuffix("\r") { text.removeLast() }
        if text.hasPrefix("\t") { return String(text.dropFirst()) }
        if text.hasPrefix("    ") { return String(text.dropFirst(4)) }
        return nil
    }

    /// The line's own line ending, so a removed definition keeps the line count.
    private static func blankLine(_ line: String) -> String {
        if line.hasSuffix("\r\n") { return "\r\n" }
        if line.hasSuffix("\n") { return "\n" }
        if line.hasSuffix("\r") { return "\r" }
        return ""
    }

    /// Replaces `[^id]` outside code with a placeholder the HTML pass turns into a link.
    private static func rewriteFootnoteReferences(
        _ source: String,
        definitions: [String: String]
    ) -> (body: String, references: [String], numbers: [Int], order: [String]) {
        guard !definitions.isEmpty, source.contains("[^") else { return (source, [], [], []) }
        let ns = source as NSString
        var result = ""
        result.reserveCapacity(ns.length + 16)
        var references: [String] = []
        var numbers: [Int] = []
        var order: [String] = []
        var numberByID: [String: Int] = [:]
        var inFence = false
        var cursor = 0
        while cursor < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                result.append(line)
            } else if inFence {
                result.append(line)
            } else {
                result.append(rewriteFootnoteLine(
                    line,
                    definitions: definitions,
                    references: &references,
                    numbers: &numbers,
                    order: &order,
                    numberByID: &numberByID
                ))
            }
            let next = NSMaxRange(lineRange)
            if next <= cursor { break }
            cursor = next
        }
        return (result, references, numbers, order)
    }

    private static func rewriteFootnoteLine(
        _ line: String,
        definitions: [String: String],
        references: inout [String],
        numbers: inout [Int],
        order: inout [String],
        numberByID: inout [String: Int]
    ) -> String {
        var result = ""
        var code = false
        var chunk = ""
        for character in line {
            if character == "`" {
                result.append(code ? chunk : rewriteFootnoteChunk(
                    chunk,
                    definitions: definitions,
                    references: &references,
                    numbers: &numbers,
                    order: &order,
                    numberByID: &numberByID
                ))
                chunk = ""
                result.append(character)
                code.toggle()
            } else {
                chunk.append(character)
            }
        }
        result.append(code ? chunk : rewriteFootnoteChunk(
            chunk,
            definitions: definitions,
            references: &references,
            numbers: &numbers,
            order: &order,
            numberByID: &numberByID
        ))
        return result
    }

    private static func rewriteFootnoteChunk(
        _ chunk: String,
        definitions: [String: String],
        references: inout [String],
        numbers: inout [Int],
        order: inout [String],
        numberByID: inout [String: Int]
    ) -> String {
        var result = ""
        var index = chunk.startIndex
        while index < chunk.endIndex {
            let next = chunk.index(after: index)
            if chunk[index] == "[", next < chunk.endIndex, chunk[next] == "^" {
                let idStart = chunk.index(after: next)
                if let close = chunk[idStart...].firstIndex(of: "]") {
                    let id = String(chunk[idStart..<close])
                    if !id.isEmpty, !id.contains(where: { $0.isWhitespace }), definitions[id] != nil {
                        let ordinal = references.count + 1
                        let number: Int
                        if let existing = numberByID[id] {
                            number = existing
                        } else {
                            number = order.count + 1
                            numberByID[id] = number
                            order.append(id)
                        }
                        references.append(id)
                        numbers.append(number)
                        result.append("\u{E000}\(ordinal)\u{E001}")
                        index = chunk.index(after: close)
                        continue
                    }
                }
            }
            result.append(chunk[index])
            index = next
        }
        return result
    }

    /// Obsidian comments (`%%...%%`) are hidden in Reading. Replace their characters with
    /// spaces so every later source line keeps its number; fenced and inline code are left
    /// alone.
    private static func maskComments(_ source: String) -> String {
        guard source.contains("%%") else { return source }
        let ns = source as NSString
        var result = ""
        result.reserveCapacity(ns.length)
        var inFence = false
        var inComment = false
        var inInlineCode = false
        var cursor = 0
        while cursor < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inComment, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                result.append(line)
                cursor = NSMaxRange(lineRange)
                continue
            }
            if inFence {
                result.append(line)
                cursor = NSMaxRange(lineRange)
                continue
            }
            var index = line.startIndex
            while index < line.endIndex {
                let character = line[index]
                if inComment {
                    if character == "%" {
                        let next = line.index(after: index)
                        if next < line.endIndex, line[next] == "%" {
                            result.append("  ")
                            index = line.index(after: next)
                            inComment = false
                            continue
                        }
                    }
                    if character == "\n" || character == "\r" {
                        result.append(character)
                    } else {
                        result.append(" ")
                    }
                    index = line.index(after: index)
                    continue
                }
                if character == "`" {
                    inInlineCode.toggle()
                    result.append(character)
                    index = line.index(after: index)
                    continue
                }
                if !inInlineCode, character == "%" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "%" {
                        result.append("  ")
                        index = line.index(after: next)
                        inComment = true
                        continue
                    }
                }
                result.append(character)
                index = line.index(after: index)
            }
            inInlineCode = false
            cursor = NSMaxRange(lineRange)
        }
        return result
    }

    /// Replaces a leading `---` block with spaces, and records simple `key: value` lines.
    private static func maskFrontMatter(_ source: String, into properties: inout Properties) -> String? {
        let ns = source as NSString
        guard ns.length >= 4, ns.hasPrefix("---") else { return nil }
        let first = ns.lineRange(for: NSRange(location: 0, length: 0))
        let opener = lineText(ns, first)
        guard opener == "---" else { return nil }
        var cursor = NSMaxRange(first)
        var scanned = 1
        var close: NSRange?
        while cursor < ns.length, scanned < 80 {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let text = lineText(ns, line)
            if text == "---" || text == "..." {
                close = line
                break
            }
            if let pair = property(text) {
                properties.pairs.append(pair)
            }
            scanned += 1
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
        }
        guard let close else {
            properties.pairs.removeAll()
            return nil
        }
        let end = NSMaxRange(close)
        var masked = ""
        masked.reserveCapacity(ns.length)
        let head = ns.substring(with: NSRange(location: 0, length: end))
        // Walk Unicode scalars, not `Character`s: Swift reads "\r\n" as one Character,
        // so a character loop replaced a CRLF front matter with spaces and joined its
        // lines into one. Every `data-line` after the front matter then moved up.
        for scalar in head.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                masked.unicodeScalars.append(scalar)
            } else {
                masked.append(" ")
            }
        }
        if end < ns.length {
            masked.append(ns.substring(from: end))
        }
        return masked
    }

    private static func property(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#") else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" "), !value.isEmpty else { return nil }
        return (String(key), String(value))
    }

    private static func lineText(_ ns: NSString, _ line: NSRange) -> String {
        var content = line
        while content.length > 0 {
            let last = ns.character(at: NSMaxRange(content) - 1)
            if last == 0x0A || last == 0x0D {
                content.length -= 1
            } else {
                break
            }
        }
        return ns.substring(with: content).trimmingCharacters(in: .whitespaces)
    }

    static func rewriteWikiLinks(_ source: String) -> String {
        // Most notes have no wiki links. Avoid scanning and copying the whole note for them.
        guard source.contains("[[") else { return source }
        let ns = source as NSString
        var result = ""
        result.reserveCapacity(ns.length + 16)
        var cursor = 0
        var inFence = false
        while cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let text = ns.substring(with: line)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                result.append(text)
            } else if inFence {
                result.append(text)
            } else {
                result.append(rewriteWikiLine(text))
            }
            let next = NSMaxRange(line)
            if next <= cursor { break }
            cursor = next
        }
        return result
    }

    private static func rewriteWikiLine(_ line: String) -> String {
        var result = ""
        var code = false
        var chunk = ""
        for character in line {
            if character == "`" {
                result.append(code ? chunk : rewriteWikiChunk(chunk))
                chunk = ""
                result.append(character)
                code.toggle()
            } else {
                chunk.append(character)
            }
        }
        result.append(code ? chunk : rewriteWikiChunk(chunk))
        return result
    }

    private static func rewriteWikiChunk(_ chunk: String) -> String {
        var result = ""
        var index = chunk.startIndex
        while index < chunk.endIndex {
            let next = chunk.index(after: index)
            if chunk[index] == "!", next < chunk.endIndex, chunk[next] == "[" {
                let afterOpen = chunk.index(after: next)
                if afterOpen < chunk.endIndex, chunk[afterOpen] == "[" {
                    let innerStart = chunk.index(after: afterOpen)
                    if let end = chunk[innerStart...].range(of: "]]"),
                       let link = wikiLink(String(chunk[innerStart..<end.lowerBound]), embed: true) {
                        result.append(link)
                        index = end.upperBound
                        continue
                    }
                }
            }
            if chunk[index] == "[", next < chunk.endIndex, chunk[next] == "[" {
                let innerStart = chunk.index(after: next)
                if let end = chunk[innerStart...].range(of: "]]"),
                   let link = wikiLink(String(chunk[innerStart..<end.lowerBound])) {
                    result.append(link)
                    index = end.upperBound
                    continue
                }
            }
            result.append(chunk[index])
            index = next
        }
        return result
    }

    /// `[[Page]]`, `[[Page|Label]]`, `[[Page#Heading]]`, `[[#Heading]]`.
    /// An embed of a picture stays an image; an embed of a note becomes a link.
    private static func wikiLink(_ inner: String, embed: Bool = false) -> String? {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("]"), !trimmed.contains("\n") else { return nil }
        let pieces = trimmed.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let target = pieces[0].trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty || pieces.count == 2 else { return nil }
        guard !target.contains(":") else { return nil }
        let alias = pieces.count == 2 ? pieces[1].trimmingCharacters(in: .whitespaces) : ""
        let hash = target.firstIndex(of: "#")
        let path = hash.map { String(target[..<$0]) } ?? target
        let fragment = hash.map { String(target[target.index(after: $0)...]) } ?? ""
        var href = ""
        if !path.isEmpty {
            href = path.contains(".") ? path : path + ".md"
            href = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? href
        }
        if !fragment.isEmpty {
            href.append("#")
            href.append(HeadingAnchor.slug(fragment))
        } else if path.isEmpty {
            return nil
        }
        let shown: String
        if !alias.isEmpty {
            shown = String(alias)
        } else if !fragment.isEmpty, path.isEmpty {
            shown = fragment
        } else {
            shown = (path as NSString).lastPathComponent
        }
        guard !shown.isEmpty, !href.isEmpty else { return nil }
        let image = embed && imageExtensions.contains((path as NSString).pathExtension.lowercased())
        return "\(image ? "!" : "")[\(shown)](\(href))"
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "avif", "bmp", "tif", "tiff",
    ]
}
