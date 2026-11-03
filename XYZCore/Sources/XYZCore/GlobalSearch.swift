import Foundation

/// One filename or path match for the folder search panel.
public struct GlobalFileHit: Equatable, Sendable {
    public var name: String
    public var relativePath: String
    public var score: Int
    /// Character indexes in `name`.
    public var nameIndices: [Int]
    /// Character indexes in `relativePath`.
    public var pathIndices: [Int]

    public init(
        name: String,
        relativePath: String,
        score: Int,
        nameIndices: [Int],
        pathIndices: [Int]
    ) {
        self.name = name
        self.relativePath = relativePath
        self.score = score
        self.nameIndices = nameIndices
        self.pathIndices = pathIndices
    }
}

/// Fuzzy file matches for ⌘K. Content search stays with the files on disk.
public enum GlobalFileSearch {
    public static let limit = 8

    public static func match(
        entries: [WorkspacePathEntry],
        query: String,
        showsHidden: Bool
    ) -> (hits: [GlobalFileHit], more: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], 0) }
        var ranked: [GlobalFileHit] = []
        for entry in entries where !entry.isDirectory {
            if !showsHidden, entry.isHidden { continue }
            let name = FuzzyMatcher.match(query: trimmed, candidate: entry.name)
            let path = FuzzyMatcher.match(query: trimmed, candidate: entry.relativePath)
            guard name != nil || path != nil else { continue }
            let score = (name?.score ?? 0) + (path?.score ?? 0) / 2 + (name == nil ? 0 : 40)
            ranked.append(GlobalFileHit(
                name: entry.name,
                relativePath: entry.relativePath,
                score: score,
                nameIndices: name?.characterIndices ?? [],
                pathIndices: path?.characterIndices ?? []
            ))
        }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        let shown = Array(ranked.prefix(limit))
        return (shown, ranked.count - shown.count)
    }
}
