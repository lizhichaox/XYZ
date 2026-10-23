import Foundation

/// A UTF-16 span in a file name or label. AppKit attributed strings use the same units.
public struct WorkspaceNameSpan: Equatable, Sendable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// One path discovered while indexing a folder. The scanner lives in the app; matching does not.
public struct WorkspacePathEntry: Equatable, Sendable, Hashable {
    public var name: String
    public var relativePath: String
    public var isDirectory: Bool
    public var isHidden: Bool

    public init(name: String, relativePath: String, isDirectory: Bool, isHidden: Bool) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isHidden = isHidden
    }
}

public struct WorkspaceSearchTree: Equatable, Sendable {
    public var children: [String: [WorkspaceNode]]
    public var highlights: [String: [WorkspaceNameSpan]]
    public var expanded: Set<String>
    public var truncated: Bool

    public init(
        children: [String: [WorkspaceNode]],
        highlights: [String: [WorkspaceNameSpan]],
        expanded: Set<String>,
        truncated: Bool
    ) {
        self.children = children
        self.highlights = highlights
        self.expanded = expanded
        self.truncated = truncated
    }
}

public enum WorkspaceNameMatching {
    /// Case-insensitive substring, otherwise a subsequence ("dn" matches "Daily notes").
    /// Empty queries do not match; callers show the unfiltered tree instead.
    public static func spans(in name: String, query: String) -> [WorkspaceNameSpan]? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if let range = name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            return [span(in: name, range: range)]
        }
        return fuzzy(name, query)
    }

    private static func span(in name: String, range: Range<String.Index>) -> WorkspaceNameSpan {
        let location = name.utf16.distance(from: name.startIndex, to: range.lowerBound)
        let length = name.utf16.distance(from: range.lowerBound, to: range.upperBound)
        return WorkspaceNameSpan(location: location, length: max(length, 0))
    }

    private static func fuzzy(_ name: String, _ query: String) -> [WorkspaceNameSpan]? {
        var spans: [WorkspaceNameSpan] = []
        var index = name.startIndex
        for character in query {
            let wanted = String(character)
            guard let found = name[index...].firstIndex(where: {
                String($0).compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else {
                return nil
            }
            let next = name.index(after: found)
            spans.append(span(in: name, range: found..<next))
            index = next
        }
        return spans.isEmpty ? nil : spans
    }
}

public enum WorkspaceTreeQuery {
    public static let matchLimit = 400

    /// Name matches, plus the folders above them so the outline can stay expanded.
    /// Hidden entries are included: a query is how you find them.
    public static func filter(entries: [WorkspacePathEntry], query: String) -> WorkspaceSearchTree {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WorkspaceSearchTree(children: [:], highlights: [:], expanded: [], truncated: false)
        }
        var nodes: [String: WorkspaceNode] = [:]
        var highlights: [String: [WorkspaceNameSpan]] = [:]
        var expanded: Set<String> = []
        var matches = 0
        var truncated = false
        for entry in entries {
            guard let spans = WorkspaceNameMatching.spans(in: entry.name, query: trimmed) else { continue }
            if matches >= matchLimit {
                truncated = true
                break
            }
            matches += 1
            nodes[entry.relativePath] = WorkspaceNode(
                name: entry.name,
                relativePath: entry.relativePath,
                isDirectory: entry.isDirectory,
                isHidden: entry.isHidden
            )
            highlights[entry.relativePath] = spans
            var parent = WorkspacePaths.parent(of: entry.relativePath)
            while !parent.isEmpty {
                expanded.insert(parent)
                if nodes[parent] == nil {
                    let name = (parent as NSString).lastPathComponent
                    nodes[parent] = WorkspaceNode(
                        name: name,
                        relativePath: parent,
                        isDirectory: true,
                        isHidden: WorkspacePaths.isHidden(name: name, resourceHidden: false)
                    )
                }
                parent = WorkspacePaths.parent(of: parent)
            }
        }
        var children: [String: [WorkspaceNode]] = [:]
        for node in nodes.values {
            children[WorkspacePaths.parent(of: node.relativePath), default: []].append(node)
        }
        for (key, value) in children {
            children[key] = WorkspaceTreeSort.ordered(value)
        }
        return WorkspaceSearchTree(
            children: children,
            highlights: highlights,
            expanded: expanded,
            truncated: truncated
        )
    }
}

public enum WorkspaceFileSymbol: String, Equatable, Sendable {
    case folder
    case folderOpen
    case markdown
    case text
    case gear
    case document
}

public enum WorkspaceFileSymbolChoice {
    public static func symbol(name: String, isDirectory: Bool, isExpanded: Bool) -> WorkspaceFileSymbol {
        if isDirectory {
            return isExpanded ? .folderOpen : .folder
        }
        if name.hasPrefix(".") {
            return .gear
        }
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown":
            return .markdown
        case "txt", "text":
            return .text
        default:
            return .document
        }
    }

    /// The extension, including the dot, when the row keeps it and draws it in a quieter color.
    public static func extensionSpan(in name: String) -> WorkspaceNameSpan? {
        let ext = (name as NSString).pathExtension
        let lowered = ext.lowercased()
        guard lowered == "md" || lowered == "markdown" || lowered == "txt" || lowered == "text" else {
            return nil
        }
        let suffix = "." + ext
        guard name.count > suffix.count, name.hasSuffix(suffix) else { return nil }
        let utf16 = (name as NSString).length
        let suffixLength = (suffix as NSString).length
        return WorkspaceNameSpan(location: utf16 - suffixLength, length: suffixLength)
    }
}

public enum WorkspaceItemName {
    public static func issue(with name: String) -> String? {
        let trimmed = normalized(name)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            return "Enter a name."
        }
        if trimmed.contains("/") || trimmed.contains(":") {
            return "Names can't include / or :."
        }
        return nil
    }

    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func unique(preferred: String, existing: Set<String>) -> String {
        if !existing.contains(preferred) { return preferred }
        let file = preferred as NSString
        let ext = file.pathExtension
        let base = file.deletingPathExtension
        var number = 2
        while number < 10_000 {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !existing.contains(candidate) { return candidate }
            number += 1
        }
        return preferred
    }

    /// A move into the item itself, into its descendant, or into its current parent is not a move.
    public static func canMove(item: String, into parent: String) -> Bool {
        if item.isEmpty { return false }
        if parent == item || parent.hasPrefix(item + "/") { return false }
        if WorkspacePaths.parent(of: item) == parent { return false }
        return true
    }
}

public struct WorkspaceContentHit: Equatable, Sendable, Identifiable {
    public var relativePath: String
    public var lineNumber: Int
    public var excerpt: String

    public var id: String { "\(relativePath)#\(lineNumber)" }

    public init(relativePath: String, lineNumber: Int, excerpt: String) {
        self.relativePath = relativePath
        self.lineNumber = lineNumber
        self.excerpt = excerpt
    }
}

/// Which files a content search may read, and how a string becomes hits.
/// Walking the directory stays in the app so this stays free of file-system policy.
public enum WorkspaceContentSearch {
    public static let maxFileBytes = 1_048_576
    public static let hitLimit = 40
    public static let skippedDirectoryNames: Set<String> = [".git", "node_modules", ".build"]

    public static func shouldSkipDirectory(_ name: String) -> Bool {
        skippedDirectoryNames.contains(name)
    }

    public static func shouldSkipRelativePath(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { skippedDirectoryNames.contains(String($0)) }
    }

    public static func shouldSkipContents(name: String, byteCount: Int, sample: Data) -> Bool {
        if byteCount > maxFileBytes || byteCount < 0 { return true }
        let kind = WorkspaceFileClassifier.kind(
            name: name,
            byteCount: min(byteCount, WorkspaceFileClassifier.editLimit),
            sample: sample
        )
        return kind != .markdown && kind != .plainText
    }

    public static func hits(in text: String, relativePath: String, query: String, limit: Int) -> [WorkspaceContentHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var found: [WorkspaceContentHit] = []
        var lineNumber = 1
        var start = text.startIndex
        while start <= text.endIndex {
            if found.count >= limit { break }
            let newline = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[start..<newline]
            if line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                found.append(WorkspaceContentHit(
                    relativePath: relativePath,
                    lineNumber: lineNumber,
                    excerpt: excerpt(String(line))
                ))
            }
            lineNumber += 1
            if newline == text.endIndex { break }
            start = text.index(after: newline)
            if start == text.endIndex, text.hasSuffix("\n") { break }
        }
        return found
    }

    public static func excerpt(_ line: String) -> String {
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= 96 { return collapsed }
        return String(collapsed.prefix(96)) + "…"
    }
}
