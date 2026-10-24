import Foundation

/// A subsequence match. `characterIndices` point at `Character`s in the candidate.
public struct FuzzyMatch: Equatable, Sendable {
    public var score: Int
    public var characterIndices: [Int]

    public init(score: Int, characterIndices: [Int]) {
        self.score = score
        self.characterIndices = characterIndices
    }
}

public enum FuzzyMatcher {
    /// Case-insensitive subsequence. Consecutive hits and word starts score higher.
    /// An empty query matches everything and highlights nothing.
    public static func match(query: String, candidate: String) -> FuzzyMatch? {
        let queryChars = Array(query)
        if queryChars.isEmpty {
            return FuzzyMatch(score: 0, characterIndices: [])
        }
        let candidateChars = Array(candidate)
        let foldedQuery = queryChars.map { String($0).lowercased() }
        let foldedCandidate = candidateChars.map { String($0).lowercased() }
        var queryIndex = 0
        var indices: [Int] = []
        var score = 0
        var previous = -2
        var index = 0
        while index < foldedCandidate.count && queryIndex < foldedQuery.count {
            if foldedCandidate[index] == foldedQuery[queryIndex] {
                score += 16
                if index == previous + 1 {
                    score += 24
                }
                if index == 0 {
                    score += 16
                } else if isBoundary(candidateChars[index - 1]) {
                    score += 12
                }
                indices.append(index)
                previous = index
                queryIndex += 1
            }
            index += 1
        }
        guard queryIndex == foldedQuery.count else { return nil }
        if indices == Array(indices.indices) {
            score += 20
        }
        return FuzzyMatch(score: score, characterIndices: indices)
    }

    private static func isBoundary(_ character: Character) -> Bool {
        switch character {
        case "/", ".", "_", "-", " ", "\\":
            return true
        default:
            return false
        }
    }
}

public struct PaletteFile: Equatable, Sendable, Identifiable {
    public var name: String
    public var relativePath: String
    /// Higher values sort first when the match scores are equal. Zero means never opened.
    public var recency: Int

    public var id: String { relativePath }

    public init(name: String, relativePath: String, recency: Int) {
        self.name = name
        self.relativePath = relativePath
        self.recency = recency
    }
}

/// One command a palette can run. Future formats and plugins register more of these.
public struct PaletteCommand: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Shown on the right of the row. Empty when the command has no shortcut.
    public var shortcut: String
    public var keywords: [String]

    public init(id: String, title: String, shortcut: String = "", keywords: [String] = []) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.keywords = keywords
    }

    public static let builtIn: [PaletteCommand] = [
        PaletteCommand(id: "view.source", title: "Source", keywords: ["mode", "edit", "coding"]),
        PaletteCommand(id: "view.reading", title: "Reading", keywords: ["mode"]),
        PaletteCommand(
            id: "view.toggleSource",
            title: "Toggle Source and Reading",
            shortcut: "⌘/",
            keywords: ["reading", "source", "coding", "edit"]
        ),
        PaletteCommand(
            id: "view.goToHeading",
            title: "Go to Heading",
            shortcut: "⌘R",
            keywords: ["outline", "toc", "heading", "jump"]
        ),
        PaletteCommand(id: "workspace.toggleSidebar", title: "Toggle Sidebar", keywords: ["sidebar"]),
        PaletteCommand(
            id: "workspace.focusFilter",
            title: "Filter Files",
            shortcut: "⇧⌘F",
            keywords: ["search", "filter"]
        ),
        PaletteCommand(id: "file.new", title: "New File", keywords: ["create"]),
        PaletteCommand(id: "folder.new", title: "New Folder", keywords: ["create"]),
        PaletteCommand(
            id: "folder.open",
            title: "Open Folder",
            shortcut: "⇧⌘O",
            keywords: ["open", "workspace"]
        ),
        PaletteCommand(id: "file.reveal", title: "Reveal in Finder", keywords: ["finder", "show"]),
        PaletteCommand(id: "file.copyPath", title: "Copy Path", keywords: ["path", "clipboard"]),
        PaletteCommand(id: "file.reload", title: "Reload", keywords: ["refresh", "disk"]),
        PaletteCommand(id: "app.about", title: "About XYZ", keywords: ["about"]),
    ]
}

public struct PaletteCommandRegistry: Equatable, Sendable {
    public private(set) var commands: [PaletteCommand]

    public init(commands: [PaletteCommand] = PaletteCommand.builtIn) {
        self.commands = commands
    }

    /// Inserts a command, or replaces the one with the same id.
    public mutating func register(_ command: PaletteCommand) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
    }
}

public enum PaletteRow: Equatable, Sendable, Identifiable {
    case file(PaletteFile, FuzzyMatch)
    case command(PaletteCommand, FuzzyMatch)
    case heading(OutlineHeading, FuzzyMatch)

    public var id: String {
        switch self {
        case .file(let file, _):
            return "file:" + file.relativePath
        case .command(let command, _):
            return "command:" + command.id
        case .heading(let heading, _):
            return "heading:\(heading.line)"
        }
    }

    public var match: FuzzyMatch {
        switch self {
        case .file(_, let match), .command(_, let match), .heading(_, let match):
            return match
        }
    }
}

/// Quick Open, a command list when the query starts with `>`, and the note's headings after `@`.
public enum CommandPalette {
    public static let rowLimit = 40

    public static func rows(
        rawQuery: String,
        files: [PaletteFile],
        registry: PaletteCommandRegistry,
        headings: [OutlineHeading] = [],
        limit: Int = rowLimit
    ) -> [PaletteRow] {
        let parsed = parse(rawQuery)
        let cap = max(0, limit)
        switch parsed.mode {
        case .files:
            return fileRows(query: parsed.text, files: files, limit: cap)
        case .commands:
            return commandRows(query: parsed.text, commands: registry.commands, limit: cap)
        case .headings:
            return headingRows(query: parsed.text, headings: headings, limit: max(cap, headings.count))
        }
    }

    public static func parse(_ rawQuery: String) -> (mode: PaletteMode, text: String) {
        if rawQuery.first == ">" {
            let text = String(rawQuery.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return (.commands, text)
        }
        if rawQuery.first == "@" {
            let text = String(rawQuery.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return (.headings, text)
        }
        return (.files, rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func fileRows(query: String, files: [PaletteFile], limit: Int) -> [PaletteRow] {
        let pool = candidates(query: query, files: files)
        var matched: [(PaletteFile, FuzzyMatch)] = []
        matched.reserveCapacity(pool.count)
        for file in pool {
            let candidate = file.relativePath.isEmpty ? file.name : file.relativePath
            guard let match = FuzzyMatcher.match(query: query, candidate: candidate) else { continue }
            matched.append((file, match))
        }
        matched.sort { lhs, rhs in
            if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
            if lhs.0.recency != rhs.0.recency { return lhs.0.recency > rhs.0.recency }
            let order = lhs.0.relativePath.localizedStandardCompare(rhs.0.relativePath)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
        }
        return matched.prefix(limit).map { .file($0.0, $0.1) }
    }

    /// An empty field lists files that were opened in this folder. If none were, it lists the folder.
    private static func candidates(query: String, files: [PaletteFile]) -> [PaletteFile] {
        guard query.isEmpty else { return files }
        let recent = files.filter { $0.recency > 0 }
        return recent.isEmpty ? files : recent
    }

    private static func commandRows(query: String, commands: [PaletteCommand], limit: Int) -> [PaletteRow] {
        if query.isEmpty {
            return commands.prefix(limit).map { command in
                .command(command, FuzzyMatch(score: 0, characterIndices: []))
            }
        }
        var matched: [(PaletteCommand, FuzzyMatch)] = []
        for command in commands {
            guard let match = commandMatch(query: query, command: command) else { continue }
            matched.append((command, match))
        }
        matched.sort { lhs, rhs in
            if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
            return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
        }
        return matched.prefix(limit).map { .command($0.0, $0.1) }
    }

    /// Every heading in order for an empty query. Otherwise the best matches, earlier lines first on a tie.
    private static func headingRows(query: String, headings: [OutlineHeading], limit: Int) -> [PaletteRow] {
        if query.isEmpty {
            return headings.prefix(limit).map { .heading($0, FuzzyMatch(score: 0, characterIndices: [])) }
        }
        var matched: [(OutlineHeading, FuzzyMatch)] = []
        for heading in headings {
            guard let match = FuzzyMatcher.match(query: query, candidate: heading.title) else { continue }
            matched.append((heading, match))
        }
        matched.sort { lhs, rhs in
            if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
            return lhs.0.line < rhs.0.line
        }
        return matched.prefix(limit).map { .heading($0.0, $0.1) }
    }

    private static func commandMatch(query: String, command: PaletteCommand) -> FuzzyMatch? {
        let title = FuzzyMatcher.match(query: query, candidate: command.title)
        let keyword = command.keywords.compactMap { FuzzyMatcher.match(query: query, candidate: $0) }
            .max { $0.score < $1.score }
        switch (title, keyword) {
        case let (title?, keyword?):
            return FuzzyMatch(score: max(title.score, keyword.score), characterIndices: title.characterIndices)
        case let (title?, nil):
            return title
        case let (nil, keyword?):
            return FuzzyMatch(score: keyword.score, characterIndices: [])
        case (nil, nil):
            return nil
        }
    }
}

public enum PaletteMode: Equatable, Sendable {
    case files
    case commands
    case headings
}
