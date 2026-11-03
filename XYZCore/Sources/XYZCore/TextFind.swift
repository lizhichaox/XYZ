import Foundation

/// What a find bar is looking for.
public struct FindQuery: Equatable, Sendable {
    public var pattern: String
    public var matchCase: Bool
    public var wholeWord: Bool
    public var regex: Bool

    public init(pattern: String, matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.pattern = pattern
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

public struct FindMatch: Equatable, Sendable {
    public var range: SourceRange

    public init(range: SourceRange) {
        self.range = range
    }
}

/// Find and replace over a string. Ranges are UTF-16, like a text view.
/// Characters outside a match, including `\r` and `\n`, are copied unchanged.
public enum TextFind {
    public static func matches(in text: String, query: FindQuery) -> [FindMatch] {
        let pattern = query.pattern
        guard !pattern.isEmpty else { return [] }
        guard let expression = expression(for: query) else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return expression.matches(in: text, options: [], range: full).compactMap { result in
            guard result.range.location != NSNotFound, result.range.length > 0 else { return nil }
            return FindMatch(range: SourceRange(location: result.range.location, length: result.range.length))
        }
    }

    /// The match after `selection`, wrapping to the start. `forward == false` walks backward.
    public static func step(from selection: SourceRange, matches: [FindMatch], forward: Bool) -> Int? {
        guard !matches.isEmpty else { return nil }
        if forward {
            if let index = matches.firstIndex(where: { $0.range.location > selection.location }) {
                return index
            }
            return 0
        }
        if let index = matches.lastIndex(where: { $0.range.location < selection.location }) {
            return index
        }
        return matches.count - 1
    }

    /// Replaces every match. The count is the number of matches, and text outside them is kept.
    public static func replaceAll(in text: String, query: FindQuery, with replacement: String) -> (text: String, count: Int) {
        guard !query.pattern.isEmpty, let expression = expression(for: query) else { return (text, 0) }
        let full = NSRange(location: 0, length: (text as NSString).length)
        let found = expression.matches(in: text, options: [], range: full)
        guard !found.isEmpty else { return (text, 0) }
        let result = NSMutableString(string: text)
        for match in found.reversed() {
            let piece = query.regex
                ? expression.replacementString(for: match, in: result as String, offset: 0, template: replacement)
                : replacement
            result.replaceCharacters(in: match.range, with: piece)
        }
        return (result as String, found.count)
    }

    public static func replacement(in text: String, match: FindMatch, query: FindQuery, with template: String) -> String {
        guard query.regex, let expression = expression(for: query) else { return template }
        let full = NSRange(location: 0, length: (text as NSString).length)
        let found = expression.matches(in: text, options: [], range: full).first {
            $0.range.location == match.range.location && $0.range.length == match.range.length
        }
        guard let found else { return template }
        return expression.replacementString(for: found, in: text, offset: 0, template: template)
    }

    public static func isValid(_ query: FindQuery) -> Bool {
        query.pattern.isEmpty || expression(for: query) != nil
    }

    private static func expression(for query: FindQuery) -> NSRegularExpression? {
        var pattern = query.regex ? query.pattern : NSRegularExpression.escapedPattern(for: query.pattern)
        if query.wholeWord {
            pattern = "(?<![\\p{L}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{N}_])"
        }
        var options: NSRegularExpression.Options = []
        if !query.matchCase {
            options.insert(.caseInsensitive)
        }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }
}

/// `*` and `?` against a relative path. An empty include list matches every path.
public enum PathGlob {
    public static func allows(_ path: String, include: String, exclude: String) -> Bool {
        let excluded = patterns(exclude)
        if excluded.contains(where: { matches(path, pattern: $0) }) { return false }
        let included = patterns(include)
        if included.isEmpty { return true }
        return included.contains { matches(path, pattern: $0) }
    }

    private static func patterns(_ raw: String) -> [String] {
        raw.split { $0 == "," || $0 == " " || $0 == "\n" }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func matches(_ path: String, pattern: String) -> Bool {
        var expression = "^"
        for character in pattern {
            switch character {
            case "*": expression += ".*"
            case "?": expression += "."
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
                expression += "\\" + String(character)
            default:
                expression += String(character)
            }
        }
        expression += "$"
        return path.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
