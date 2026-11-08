import Foundation

/// Finds the bracket that pairs with the one next to the caret.
///
/// The scan is deliberately lexical: it balances brackets of the same kind and gives up
/// after `limit` characters so a click in a one-line minified file cannot stall the
/// editor. It does not try to skip strings or comments; the caret's own bracket is the
/// anchor either way.
public enum BracketMatching {
    public struct Pair: Equatable, Sendable {
        public var opener: NSRange
        public var closer: NSRange

        public init(opener: NSRange, closer: NSRange) {
            self.opener = opener
            self.closer = closer
        }
    }

    private static func code(_ character: Character) -> unichar {
        unichar(character.unicodeScalars.first!.value)
    }

    private static let openers: [unichar: unichar] = [
        code("("): code(")"),
        code("["): code("]"),
        code("{"): code("}"),
    ]
    private static let closers: [unichar: unichar] = [
        code(")"): code("("),
        code("]"): code("["),
        code("}"): code("{"),
    ]

    /// The caret can sit before a bracket or right after it; both count.
    public static func pair(in text: NSString, caretOffset: Int, limit: Int = 20_000) -> Pair? {
        let length = text.length
        guard length > 0 else { return nil }
        let clamped = min(max(0, caretOffset), length)
        if clamped < length, let found = pair(anchorAt: clamped, character: text.character(at: clamped), text: text, limit: limit) {
            return found
        }
        if clamped > 0, let found = pair(anchorAt: clamped - 1, character: text.character(at: clamped - 1), text: text, limit: limit) {
            return found
        }
        return nil
    }

    private static func pair(anchorAt offset: Int, character: unichar, text: NSString, limit: Int) -> Pair? {
        if let expected = openers[character] {
            var depth = 0
            var index = offset
            let stop = min(text.length, offset + limit)
            while index < stop {
                let current = text.character(at: index)
                if current == character {
                    depth += 1
                } else if current == expected {
                    depth -= 1
                    if depth == 0 {
                        return Pair(
                            opener: NSRange(location: offset, length: 1),
                            closer: NSRange(location: index, length: 1)
                        )
                    }
                }
                index += 1
            }
            return nil
        }
        if let expected = closers[character] {
            var depth = 0
            var index = offset
            let stop = max(0, offset - limit)
            while index >= stop {
                let current = text.character(at: index)
                if current == character {
                    depth += 1
                } else if current == expected {
                    depth -= 1
                    if depth == 0 {
                        return Pair(
                            opener: NSRange(location: index, length: 1),
                            closer: NSRange(location: offset, length: 1)
                        )
                    }
                }
                index -= 1
            }
            return nil
        }
        return nil
    }
}

/// The identifier around the caret, and its other whole-word occurrences.
public enum WordOccurrences {
    /// `offset` may be the caret (before a word) or inside a word.
    public static func wordRange(in text: NSString, at offset: Int) -> NSRange? {
        let length = text.length
        guard length > 0 else { return nil }
        let clamped = min(max(0, offset), length)
        var start = clamped
        if start == length || !isWordCharacter(text.character(at: start)) {
            guard start > 0, isWordCharacter(text.character(at: start - 1)) else { return nil }
            start -= 1
        }
        var end = start
        while start > 0, isWordCharacter(text.character(at: start - 1)) {
            start -= 1
        }
        while end < length, isWordCharacter(text.character(at: end)) {
            end += 1
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    public static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        if scalar == "_" { return true }
        let properties = scalar.properties
        if properties.isAlphabetic { return true }
        return CharacterSet.decimalDigits.contains(scalar)
    }

    /// Other whole-word occurrences of `word` inside `range`, at most `limit`, excluding
    /// `excluding`. A word must have a word character on neither side to count.
    public static func matches(
        of word: NSRange,
        in text: NSString,
        within window: NSRange,
        limit: Int,
        excluding: [NSRange]
    ) -> [NSRange] {
        guard word.length > 0, window.length > 0 else { return [] }
        let haystack = text.substring(with: word)
        guard !haystack.isEmpty else { return [] }
        var results: [NSRange] = []
        var location = window.location
        let end = NSMaxRange(window)
        while location < end, results.count < limit {
            let searchRange = NSRange(location: location, length: end - location)
            let found = text.range(of: haystack, options: [], range: searchRange)
            if found.location == NSNotFound { break }
            let beforeOK = found.location == 0 || !isWordCharacter(text.character(at: found.location - 1))
            let afterOK = NSMaxRange(found) >= text.length
                || !isWordCharacter(text.character(at: NSMaxRange(found)))
            if beforeOK, afterOK, !excluding.contains(where: { NSEqualRanges($0, found) }) {
                results.append(found)
            }
            location = NSMaxRange(found)
        }
        return results
    }
}
