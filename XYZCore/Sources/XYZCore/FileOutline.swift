import Foundation

/// One row in the outline: a heading, a JSON key, or a declaration.
public struct OutlineEntry: Equatable, Sendable, Identifiable {
    public var title: String
    public var line: Int
    /// Zero is the top level. Nested keys and indented declarations sit deeper.
    public var depth: Int

    public var id: String { "\(line):\(depth):\(title)" }

    public init(title: String, line: Int, depth: Int) {
        self.title = title
        self.line = line
        self.depth = max(0, depth)
    }
}

/// A small outline for the open file. Markdown uses the same parser as Reading.
/// JSON keys and declarations are a straight scan. There is no language server.
public enum FileOutline {
    /// Past this many scalars the rest of the file is left out, so a huge file stays responsive.
    public static let scalarLimit = 250_000

    public static func entries(in text: String, language: SyntaxLanguage) -> [OutlineEntry] {
        let limited = limit(text)
        switch language {
        case .markdown:
            return MarkdownOutline.headings(in: limited).map {
                OutlineEntry(title: $0.title, line: $0.line, depth: max(0, $0.level - 1))
            }
        case .json:
            return jsonKeys(in: limited)
        case .plain, .csv, .log, .ini:
            return []
        default:
            return declarations(in: limited)
        }
    }

    private static func limit(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > scalarLimit else { return text }
        return String(scalars.prefix(scalarLimit))
    }

    private static func jsonKeys(in text: String) -> [OutlineEntry] {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        var line = 1
        var inString = false
        var escape = false
        var token = ""
        var tokenLine = 1
        var stack: [Bool] = []
        var entries: [OutlineEntry] = []

        func advance() {
            index = scalars.index(after: index)
        }

        while index < scalars.endIndex, entries.count < 4_000 {
            let scalar = scalars[index]
            if !inString, scalar == "\n" {
                line += 1
                advance()
                continue
            }
            if !inString, scalar == "\r" {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    index = next
                    continue
                }
                line += 1
                advance()
                continue
            }
            if inString {
                if escape {
                    escape = false
                    token.unicodeScalars.append(scalar)
                    advance()
                    continue
                }
                if scalar == "\\" {
                    escape = true
                    advance()
                    continue
                }
                if scalar == "\"" {
                    inString = false
                    if stack.last == true, followedByColon(scalars, from: scalars.index(after: index)) {
                        let title = token.isEmpty ? "\"\"" : token
                        entries.append(OutlineEntry(title: title, line: tokenLine, depth: max(0, stack.count - 1)))
                    }
                    token = ""
                    advance()
                    continue
                }
                if scalar == "\n" { line += 1 }
                token.unicodeScalars.append(scalar)
                advance()
                continue
            }
            if scalar == "\"" {
                inString = true
                token = ""
                tokenLine = line
                advance()
                continue
            }
            if scalar == "{" {
                stack.append(true)
            } else if scalar == "[" {
                stack.append(false)
            } else if scalar == "}" || scalar == "]" {
                if !stack.isEmpty { stack.removeLast() }
            }
            advance()
        }
        return entries
    }

    private static func followedByColon(
        _ scalars: String.UnicodeScalarView,
        from start: String.UnicodeScalarView.Index
    ) -> Bool {
        var cursor = start
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                cursor = scalars.index(after: cursor)
                continue
            }
            return scalar == ":"
        }
        return false
    }

    private static let declarations: Set<String> = [
        "func", "function", "fn", "def", "class", "struct", "enum", "protocol",
        "interface", "impl", "trait", "type",
    ]
    private static let modifiers: Set<String> = [
        "public", "private", "open", "internal", "fileprivate", "static", "final",
        "override", "mutating", "async", "export", "default", "pub", "abstract", "sealed",
    ]

    private static func declarations(in text: String) -> [OutlineEntry] {
        var entries: [OutlineEntry] = []
        var lineNumber = 1
        var current = ""
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        func finishLine() {
            if let entry = declaration(on: current, line: lineNumber), entries.count < 4_000 {
                entries.append(entry)
            }
            current = ""
            lineNumber += 1
        }
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" {
                finishLine()
            } else if scalar == "\r" {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    index = next
                }
                finishLine()
            } else {
                current.unicodeScalars.append(scalar)
            }
            index = scalars.index(after: index)
        }
        if !current.isEmpty {
            finishLine()
        }
        return entries
    }

    private static func declaration(on line: String, line number: Int) -> OutlineEntry? {
        var indent = 0
        let scalars = line.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == " " {
                indent += 1
            } else if scalar == "\t" {
                indent += 4
            } else {
                break
            }
            index = scalars.index(after: index)
        }
        let trimmed = String(scalars[index...]).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
            return nil
        }
        var parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = parts.first {
            if declarations.contains(first) {
                if (first == "class" || first == "static"), parts.count > 1, declarations.contains(parts[1]) {
                    parts.removeFirst()
                    continue
                }
                break
            }
            if modifiers.contains(first) || first.hasPrefix("@") {
                parts.removeFirst()
                continue
            }
            return nil
        }
        guard let keyword = parts.first, declarations.contains(keyword) else { return nil }
        var name = parts.dropFirst().first ?? keyword
        if let cut = name.firstIndex(where: { "({:<".contains($0) }) {
            name = String(name[..<cut])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = keyword }
        if name.count > 80 { name = String(name.prefix(80)) }
        return OutlineEntry(title: name, line: number, depth: min(8, indent / 2))
    }
}
