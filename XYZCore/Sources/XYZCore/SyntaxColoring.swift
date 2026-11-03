import Foundation

public enum SyntaxTokenKind: Equatable, Sendable {
    case keyword
    case string
    case comment
    case number
    case type
    case key
}

/// One colored range, in UTF-16 offsets, matching `NSTextStorage`.
public struct SyntaxSpan: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var kind: SyntaxTokenKind

    public init(location: Int, length: Int, kind: SyntaxTokenKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}

/// Plain syntax coloring. Comments, strings, numbers, and keywords only.
/// There is no completion, diagnostics, or language server.
public enum SyntaxColoring {
    /// Files larger than this are left uncolored so a keystroke does not walk a huge buffer.
    public static let scanLimit = 250_000

    public static func spans(
        in text: String,
        language: SyntaxLanguage,
        within utf16: Range<Int>? = nil
    ) -> [SyntaxSpan] {
        guard let rules = rules(for: language) else { return [] }
        let ns = text as NSString
        guard ns.length > 0, ns.length <= scanLimit else { return [] }
        let limit = min(ns.length, utf16?.upperBound ?? ns.length)
        let emitFrom = utf16?.lowerBound ?? 0
        return scan(ns, rules: rules, limit: limit, emitFrom: emitFrom)
    }

    private struct Rules {
        var lineComments: [String]
        var blockComment: (start: String, end: String)?
        var quotes: [Character]
        var tripleQuote: Bool
        var keywords: Set<String>
        var markupTags: Bool
        var caseInsensitive: Bool = false
        var properties: Bool = false
        var types: Bool = false
    }

    private static func rules(for language: SyntaxLanguage) -> Rules? {
        switch language {
        case .plain, .markdown, .csv, .log:
            return nil
        case .json:
            return Rules(lineComments: [], blockComment: nil, quotes: ["\""], tripleQuote: false, keywords: ["true", "false", "null"], markupTags: false)
        case .yaml:
            return Rules(lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"], tripleQuote: false, keywords: ["true", "false", "null", "yes", "no"], markupTags: false)
        case .toml, .shell, .ruby, .python, .ini:
            return Rules(
                lineComments: language == .ini ? ["#", ";"] : ["#"],
                blockComment: nil,
                quotes: ["\"", "'"],
                tripleQuote: language == .python,
                keywords: keywords(language),
                markupTags: false,
                properties: language == .ini
            )
        case .html, .xml:
            return Rules(lineComments: [], blockComment: ("<!--", "-->"), quotes: ["\"", "'"], tripleQuote: false, keywords: [], markupTags: true)
        case .css:
            return Rules(lineComments: [], blockComment: ("/*", "*/"), quotes: ["\"", "'"], tripleQuote: false, keywords: [], markupTags: false)
        case .sql:
            return Rules(lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""], tripleQuote: false, keywords: keywords(language), markupTags: false, caseInsensitive: true)
        default:
            return Rules(
                lineComments: ["//"],
                blockComment: ("/*", "*/"),
                quotes: language == .go || language == .rust ? ["\"", "`"] : ["\"", "'"],
                tripleQuote: language == .swift || language == .kotlin,
                keywords: keywords(language),
                markupTags: false,
                types: true
            )
        }
    }

    private static func scan(_ ns: NSString, rules: Rules, limit: Int, emitFrom: Int) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var index = 0
        while index < limit {
            if let end = lineCommentEnd(ns, at: index, limit: limit, rules: rules) {
                emit(&spans, location: index, end: end, kind: .comment, emitFrom: emitFrom)
                index = end
                continue
            }
            if matchBlock(ns, at: &index, limit: limit, rules: rules, spans: &spans, emitFrom: emitFrom) { continue }
            if matchString(ns, at: &index, limit: limit, rules: rules, spans: &spans, emitFrom: emitFrom) { continue }
            let character = ns.character(at: index)
            if rules.markupTags, character == 0x3C {
                if matchTag(ns, at: &index, limit: limit, spans: &spans, emitFrom: emitFrom) { continue }
            }
            if isNumberStart(ns, at: index), !previousIsIdentifier(ns, at: index) {
                let end = consumeNumber(ns, from: index, limit: limit)
                emit(&spans, location: index, end: end, kind: .number, emitFrom: emitFrom)
                index = end
                continue
            }
            if rules.properties, atLineStart(ns, index), matchProperty(ns, at: &index, limit: limit, spans: &spans, emitFrom: emitFrom) {
                continue
            }
            if isIdentifierStart(character) {
                let end = consumeIdentifier(ns, from: index, limit: limit)
                let word = ns.substring(with: NSRange(location: index, length: end - index))
                let isKeyword = rules.keywords.contains(word)
                    || (rules.caseInsensitive && rules.keywords.contains(word.lowercased()))
                if isKeyword {
                    emit(&spans, location: index, end: end, kind: .keyword, emitFrom: emitFrom)
                } else if rules.types, isTypeName(word) {
                    emit(&spans, location: index, end: end, kind: .type, emitFrom: emitFrom)
                }
                index = end
                continue
            }
            index += 1
        }
        return spans
    }

    private static func lineCommentEnd(_ ns: NSString, at index: Int, limit: Int, rules: Rules) -> Int? {
        let rest = ns.substring(with: NSRange(location: index, length: min(4, limit - index)))
        guard let marker = rules.lineComments.first(where: { rest.hasPrefix($0) }) else { return nil }
        if marker == "#", index > 0, isIdentifier(ns.character(at: index - 1)) { return nil }
        var end = index + (marker as NSString).length
        while end < limit {
            let character = ns.character(at: end)
            end += 1
            if character == 0x0A || character == 0x0D { break }
        }
        return end
    }

    private static func matchBlock(
        _ ns: NSString,
        at index: inout Int,
        limit: Int,
        rules: Rules,
        spans: inout [SyntaxSpan],
        emitFrom: Int
    ) -> Bool {
        guard let block = rules.blockComment else { return false }
        let start = block.start as NSString
        guard index + start.length <= limit,
              ns.substring(with: NSRange(location: index, length: start.length)) == block.start else { return false }
        let endMarker = block.end as NSString
        var cursor = index + start.length
        var found = limit
        while cursor + endMarker.length <= limit {
            if ns.substring(with: NSRange(location: cursor, length: endMarker.length)) == block.end {
                found = cursor + endMarker.length
                break
            }
            cursor += 1
        }
        emit(&spans, location: index, end: found, kind: .comment, emitFrom: emitFrom)
        index = found
        return true
    }

    private static func matchString(
        _ ns: NSString,
        at index: inout Int,
        limit: Int,
        rules: Rules,
        spans: inout [SyntaxSpan],
        emitFrom: Int
    ) -> Bool {
        let unit = ns.character(at: index)
        let quoted = rules.quotes.contains { quote in
            quote.unicodeScalars.first?.value == UInt32(unit)
        }
        guard quoted || (rules.tripleQuote && unit == 0x22) else { return false }
        let quote = unit
        var triple = false
        var start = index
        if rules.tripleQuote, quote == 0x22, index + 2 < limit,
           ns.character(at: index + 1) == 0x22, ns.character(at: index + 2) == 0x22 {
            triple = true
            start = index
        }
        var cursor = index + (triple ? 3 : 1)
        while cursor < limit {
            let current = ns.character(at: cursor)
            if current == 0x5C, !triple { // backslash
                cursor = min(limit, cursor + 2)
                continue
            }
            if triple {
                if current == 0x22, cursor + 2 < limit,
                   ns.character(at: cursor + 1) == 0x22, ns.character(at: cursor + 2) == 0x22 {
                    cursor += 3
                    break
                }
            } else if current == quote || current == 0x0A || current == 0x0D {
                cursor += current == quote ? 1 : 0
                break
            }
            cursor += 1
        }
        emit(&spans, location: start, end: cursor, kind: .string, emitFrom: emitFrom)
        index = cursor
        return true
    }

    private static func matchTag(
        _ ns: NSString,
        at index: inout Int,
        limit: Int,
        spans: inout [SyntaxSpan],
        emitFrom: Int
    ) -> Bool {
        var cursor = index + 1
        if cursor < limit, ns.character(at: cursor) == 0x2F { cursor += 1 }
        let name = cursor
        while cursor < limit, isIdentifier(ns.character(at: cursor)) { cursor += 1 }
        guard cursor > name else {
            index += 1
            return true
        }
        emit(&spans, location: name, end: cursor, kind: .keyword, emitFrom: emitFrom)
        index = cursor
        return true
    }

    private static func emit(
        _ spans: inout [SyntaxSpan],
        location: Int,
        end: Int,
        kind: SyntaxTokenKind,
        emitFrom: Int
    ) {
        guard end > location, end > emitFrom else { return }
        let start = max(location, emitFrom)
        spans.append(SyntaxSpan(location: start, length: end - start, kind: kind))
    }

    /// `[section]` or `key = value` on one line. The value is left for the string and number scanners.
    private static func matchProperty(
        _ ns: NSString,
        at index: inout Int,
        limit: Int,
        spans: inout [SyntaxSpan],
        emitFrom: Int
    ) -> Bool {
        let character = ns.character(at: index)
        if character == 0x5B { // [
            var end = index + 1
            while end < limit {
                let next = ns.character(at: end)
                end += 1
                if next == 0x5D || next == 0x0A || next == 0x0D { break }
            }
            emit(&spans, location: index, end: end, kind: .type, emitFrom: emitFrom)
            index = end
            return true
        }
        var cursor = index
        var equals = -1
        while cursor < limit {
            let next = ns.character(at: cursor)
            if next == 0x0A || next == 0x0D { break }
            if next == 0x3D, equals < 0 { // =
                equals = cursor
                break
            }
            cursor += 1
        }
        guard equals > index else { return false }
        emit(&spans, location: index, end: equals, kind: .key, emitFrom: emitFrom)
        index = equals + 1
        return true
    }

    private static func atLineStart(_ ns: NSString, _ index: Int) -> Bool {
        if index == 0 { return true }
        let previous = ns.character(at: index - 1)
        return previous == 0x0A || previous == 0x0D
    }

    private static func isTypeName(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        return CharacterSet.uppercaseLetters.contains(first)
    }

    private static func isNumberStart(_ ns: NSString, at index: Int) -> Bool {
        let character = ns.character(at: index)
        return character >= 0x30 && character <= 0x39
    }

    private static func previousIsIdentifier(_ ns: NSString, at index: Int) -> Bool {
        guard index > 0 else { return false }
        return isIdentifier(ns.character(at: index - 1))
    }

    private static func consumeNumber(_ ns: NSString, from index: Int, limit: Int) -> Int {
        var cursor = index + 1
        while cursor < limit {
            let character = ns.character(at: cursor)
            let digit = character >= 0x30 && character <= 0x39
            let hex = (character >= 0x41 && character <= 0x46) || (character >= 0x61 && character <= 0x66)
            let dot = character == 0x2E || character == 0x5F || character == 0x78
            if digit || hex || dot {
                cursor += 1
            } else {
                break
            }
        }
        return cursor
    }

    private static func consumeIdentifier(_ ns: NSString, from index: Int, limit: Int) -> Int {
        var cursor = index + 1
        while cursor < limit, isIdentifier(ns.character(at: cursor)) { cursor += 1 }
        return cursor
    }

    private static func isIdentifierStart(_ character: unichar) -> Bool {
        if character == 0x5F || character == 0x24 { return true }
        if character >= 0x41 && character <= 0x5A { return true }
        if character >= 0x61 && character <= 0x7A { return true }
        return character > 0x7F
    }

    private static func isIdentifier(_ character: unichar) -> Bool {
        if character >= 0x30 && character <= 0x39 { return true }
        return isIdentifierStart(character)
    }

    private static func keywords(_ language: SyntaxLanguage) -> Set<String> {
        switch language {
        case .swift:
            return [
                "class", "struct", "enum", "protocol", "extension", "func", "var", "let", "if", "else",
                "guard", "return", "switch", "case", "default", "for", "while", "in", "import",
                "public", "private", "internal", "fileprivate", "open", "static", "true", "false",
                "nil", "self", "init", "throws", "throw", "try", "catch", "async", "await", "where",
                "associatedtype", "typealias", "override", "final", "weak", "inout", "break", "continue",
                "defer", "as", "is", "some", "any",
            ]
        case .javascript, .typescript:
            return [
                "const", "let", "var", "function", "return", "if", "else", "for", "while", "class",
                "extends", "new", "this", "import", "export", "from", "async", "await", "true",
                "false", "null", "undefined", "of", "in", "switch", "case", "default", "break",
                "continue", "try", "catch", "throw", "typeof", "yield", "static",
            ]
        case .python:
            return [
                "def", "class", "return", "if", "elif", "else", "for", "while", "in", "import",
                "from", "as", "try", "except", "finally", "with", "lambda", "True", "False", "None",
                "pass", "break", "continue", "yield", "async", "await", "not", "and", "or", "is",
                "raise", "assert",
            ]
        case .go:
            return [
                "func", "var", "const", "type", "struct", "interface", "package", "import", "return",
                "if", "else", "for", "range", "switch", "case", "default", "break", "continue",
                "go", "defer", "map", "true", "false", "nil",
            ]
        case .rust:
            return [
                "fn", "let", "mut", "struct", "enum", "impl", "trait", "pub", "use", "mod", "return",
                "if", "else", "match", "for", "while", "loop", "in", "true", "false", "self", "where",
                "async", "await", "type", "const", "static", "unsafe", "dyn", "crate",
            ]
        case .c, .java, .kotlin, .php:
            return [
                "if", "else", "for", "while", "return", "switch", "case", "default", "break",
                "continue", "class", "struct", "enum", "public", "private", "protected", "static",
                "void", "int", "bool", "true", "false", "null", "nil", "new", "func", "function",
                "import", "package", "extends", "implements", "interface", "try", "catch", "throw",
                "var", "let", "val", "fun", "const",
            ]
        case .shell:
            return [
                "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                "function", "return", "in", "select", "until",
            ]
        case .sql:
            return [
                "select", "from", "where", "and", "or", "insert", "into", "values", "update", "set",
                "delete", "create", "table", "join", "left", "right", "inner", "on", "group", "by",
                "order", "limit", "as", "null", "not", "primary", "key", "distinct",
            ]
        case .ruby:
            return [
                "def", "end", "class", "module", "do", "if", "else", "elsif", "unless", "return",
                "true", "false", "nil", "self", "require", "begin", "rescue", "ensure",
            ]
        case .toml:
            return ["true", "false"]
        default:
            return []
        }
    }
}
