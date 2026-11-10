import Foundation

/// One note that links to the open note.
public struct Backlink: Equatable, Sendable, Identifiable {
    public var relativePath: String
    /// Link from the open note's folder to this note.
    public var href: String
    public var title: String
    public var line: Int
    public var excerpt: String

    public var id: String { "\(relativePath):\(line)" }

    public init(relativePath: String, href: String, title: String, line: Int, excerpt: String) {
        self.relativePath = relativePath
        self.href = href
        self.title = title
        self.line = line
        self.excerpt = excerpt
    }
}

/// Finds notes that link to the open note. Wiki links and Markdown links are both read;
/// fenced code and inline code are ignored.
public enum BacklinkIndex {
    public struct LinkOccurrence: Equatable, Sendable {
        public var target: String
        public var line: Int
        public var excerpt: String

        public init(target: String, line: Int, excerpt: String) {
            self.target = target
            self.line = line
            self.excerpt = excerpt
        }
    }

    public static func links(in text: String, relativePath: String) -> [LinkOccurrence] {
        _ = relativePath
        // Most notes have no links. Skip the line scan entirely for them.
        guard text.contains("[[") || text.contains("](") else { return [] }
        let ns = text as NSString
        var occurrences: [LinkOccurrence] = []
        var lineNumber = 1
        var location = 0
        var inFence = false
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            var content = lineRange
            while content.length > 0 {
                let last = ns.character(at: NSMaxRange(content) - 1)
                if last == 0x0A || last == 0x0D {
                    content.length -= 1
                } else {
                    break
                }
            }
            let line = ns.substring(with: content)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            } else if !inFence {
                let visible = withoutInlineCode(line)
                guard visible.contains("[[") || visible.contains("](") else {
                    let next = NSMaxRange(lineRange)
                    if next <= location { break }
                    location = next
                    lineNumber += 1
                    continue
                }
                let excerpt = String(trimmed.prefix(120))
                for target in wikiTargets(in: visible) + markdownTargets(in: visible) {
                    occurrences.append(LinkOccurrence(target: target, line: lineNumber, excerpt: excerpt))
                }
            }
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
            lineNumber += 1
        }
        return occurrences
    }

    public static func backlinks(
        to target: String,
        in files: [(relativePath: String, text: String)]
    ) -> [Backlink] {
        let known = Set(files.map(\.relativePath))
        let targetDirectory = WorkspacePaths.parent(of: target)
        var found: [Backlink] = []
        var seen: Set<String> = []
        for file in files where file.relativePath != target {
            for link in links(in: file.text, relativePath: file.relativePath) {
                guard resolve(link.target, from: file.relativePath, knownPaths: known) == target else { continue }
                let key = "\(file.relativePath):\(link.line)"
                guard seen.insert(key).inserted else { continue }
                found.append(Backlink(
                    relativePath: file.relativePath,
                    href: WorkspacePaths.relativeLink(from: targetDirectory, to: file.relativePath),
                    title: (file.relativePath as NSString).lastPathComponent,
                    line: link.line,
                    excerpt: link.excerpt
                ))
            }
        }
        return found.sorted {
            if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
            return $0.line < $1.line
        }
    }

    /// Resolves a link target from `source` to a workspace-relative path.
    public static func resolve(_ rawTarget: String, from source: String, knownPaths: Set<String>) -> String? {
        var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pipe = target.firstIndex(of: "|") { target = String(target[..<pipe]) }
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let sourceDirectory = WorkspacePaths.parent(of: source)
        let hasExtension = ["md", "markdown", "txt"].contains((target as NSString).pathExtension.lowercased())
        var candidates: [String] = []
        if target.hasPrefix("/") {
            candidates.append(String(target.dropFirst()))
        } else if target.contains("/") {
            candidates.append(target)
            candidates.append(join(sourceDirectory, target))
        } else {
            if let match = basenameMatch(target, knownPaths: knownPaths) { return match }
            candidates.append(target)
            candidates.append(join(sourceDirectory, target))
        }
        for candidate in candidates {
            for path in expanded(candidate, hasExtension: hasExtension) {
                if knownPaths.contains(path) { return path }
                if let match = knownPaths.first(where: { $0.lowercased() == path.lowercased() }) {
                    return match
                }
            }
        }
        return nil
    }

    private static func wikiTargets(in line: String) -> [String] {
        matches(wikiRegex, in: line)
    }

    private static func markdownTargets(in line: String) -> [String] {
        matches(markdownRegex, in: line).compactMap { raw in
            var target = raw.trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("<"), let end = target.firstIndex(of: ">") {
                target = String(target[target.index(after: target.startIndex)..<end])
            } else if let space = target.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                target = String(target[..<space])
            }
            return target.isEmpty ? nil : target
        }
    }

    private static func matches(_ regex: NSRegularExpression?, in line: String) -> [String] {
        guard let regex else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, options: [], range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    private static let wikiRegex = try? NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)
    private static let markdownRegex = try? NSRegularExpression(pattern: #"\[[^\]\n]*\]\(([^)\n]+)\)"#)

    private static func withoutInlineCode(_ line: String) -> String {
        guard line.contains("`") else { return line }
        var result = ""
        var inCode = false
        for character in line {
            if character == "`" {
                inCode.toggle()
                result.append(" ")
            } else {
                result.append(inCode ? " " : character)
            }
        }
        return result
    }

    private static func basenameMatch(_ target: String, knownPaths: Set<String>) -> String? {
        let wanted = target.lowercased()
        let matches = knownPaths.filter { path in
            let name = (path as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            return stem.lowercased() == wanted
        }
        return matches.min {
            let left = $0.split(separator: "/").count
            let right = $1.split(separator: "/").count
            if left != right { return left < right }
            return $0 < $1
        }
    }

    private static func expanded(_ path: String, hasExtension: Bool) -> [String] {
        let normalized = normalize(path)
        guard !hasExtension else { return [normalized] }
        return [normalized + ".md", normalized + ".markdown", normalized]
    }

    private static func join(_ directory: String, _ path: String) -> String {
        directory.isEmpty ? path : directory + "/" + path
    }

    private static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        return parts.joined(separator: "/")
    }
}

/// The Reading footer that lists notes linking to the open note.
public enum BacklinkHTML {
    public static func render(_ backlinks: [Backlink]) -> String {
        guard !backlinks.isEmpty else { return "" }
        var html = "<section class=\"backlinks\">\n<h2>Backlinks</h2>\n<ul>\n"
        for backlink in backlinks {
            html.append("<li><a href=\"")
            html.append(HTMLText.attribute(backlink.href))
            html.append("\">")
            html.append(HTMLText.escape(backlink.title))
            html.append("</a> <span class=\"backlink-line\">Ln ")
            html.append(String(backlink.line))
            html.append("</span><p>")
            html.append(HTMLText.escape(backlink.excerpt))
            html.append("</p></li>\n")
        }
        html.append("</ul>\n</section>\n")
        return html
    }
}
