import Foundation

/// How a Markdown document is shown.
///
/// Source is the editor. Reading is the rendered note. One of them fills the
/// content area. A saved Preview or Coding value from an older build becomes Source,
/// unless the saved value is Reading.
public enum EditorViewMode: String, CaseIterable, Sendable, Identifiable, Equatable {
    case source
    case reading

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .source: return "Source"
        case .reading: return "Reading"
        }
    }

    /// Reading stays Reading. Preview, Coding, and anything else become Source.
    public static func restored(_ raw: String?) -> EditorViewMode {
        raw == EditorViewMode.reading.rawValue ? .reading : .source
    }

    public func toggled() -> EditorViewMode {
        self == .reading ? .source : .reading
    }
}

extension EditorViewMode: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = EditorViewMode.restored(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where to put the other view after a Source/Reading toggle.
///
/// `line` is the 1-based source line at the top of the viewport. It is the position
/// that survives a toggle. `fraction` and `probe` remain for a document that has no
/// line number yet.
public struct EditorScrollAnchor: Equatable, Sendable {
    public var fraction: Double
    public var probe: String
    public var line: Int

    public init(fraction: Double, probe: String, line: Int = 0) {
        self.fraction = min(1, max(0, fraction))
        self.probe = probe
        self.line = max(0, line)
    }

    public func lineIndex(in text: String) -> Int {
        let lines = Self.lines(in: text)
        guard lines.count > 1 else { return 0 }
        let estimated = Int((fraction * Double(lines.count - 1)).rounded())
        let needle = probe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return estimated }
        let matches = lines.enumerated().compactMap { index, line in
            line.contains(needle) ? index : nil
        }
        guard let nearest = matches.min(by: { abs($0 - estimated) < abs($1 - estimated) }) else {
            return estimated
        }
        return nearest
    }

    /// UTF-16 offset of the line at the top. A known source line wins over the fraction.
    public func utf16Location(in text: String) -> Int {
        if line > 0 {
            return Self.utf16Location(ofLine: line, in: text)
        }
        let ns = text as NSString
        if ns.length == 0 { return 0 }
        let target = lineIndex(in: text)
        var line = 0
        var cursor = 0
        while line < target && cursor < ns.length {
            let range = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(range)
            if next <= cursor { break }
            cursor = next
            line += 1
        }
        return min(cursor, ns.length)
    }

    /// 1-based source line containing the UTF-16 offset.
    public static func lineNumber(at utf16: Int, in text: String) -> Int {
        let ns = text as NSString
        if ns.length == 0 { return 1 }
        let limit = min(max(0, utf16), ns.length)
        var line = 1
        var index = 0
        while index < limit {
            let character = ns.character(at: index)
            if character == 0x0A {
                line += 1
            } else if character == 0x0D {
                line += 1
                if index + 1 < limit, ns.character(at: index + 1) == 0x0A {
                    index += 1
                }
            }
            index += 1
        }
        return line
    }

    /// UTF-16 offset where the 1-based source line begins.
    public static func utf16Location(ofLine line: Int, in text: String) -> Int {
        let ns = text as NSString
        if ns.length == 0 || line <= 1 { return 0 }
        var current = 1
        var index = 0
        while index < ns.length && current < line {
            let character = ns.character(at: index)
            index += 1
            if character == 0x0A {
                current += 1
            } else if character == 0x0D {
                if index < ns.length, ns.character(at: index) == 0x0A {
                    index += 1
                }
                current += 1
            }
        }
        return min(index, ns.length)
    }

    /// Words from a source line, without a leading heading or list marker.
    public static func probe(from line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") {
            text.removeFirst()
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("> ") {
            text = String(text.dropFirst(2))
        }
        if text.count > 80 {
            text = String(text.prefix(80))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lines(in text: String) -> [String] {
        let ns = text as NSString
        if ns.length == 0 { return [""] }
        var lines: [String] = []
        var cursor = 0
        while cursor <= ns.length {
            let range = ns.lineRange(for: NSRange(location: min(cursor, ns.length), length: 0))
            var content = range
            if content.length > 0 {
                let last = ns.character(at: NSMaxRange(content) - 1)
                if last == 0x0A || last == 0x0D {
                    content.length -= 1
                    if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 0x0D {
                        content.length -= 1
                    }
                }
            }
            lines.append(ns.substring(with: content))
            let next = NSMaxRange(range)
            if next <= cursor { break }
            cursor = next
            if cursor == ns.length { break }
        }
        return lines.isEmpty ? [""] : lines
    }
}

/// Maps a source line to the rendered block that contains it, and back.
///
/// Lines are 1-based, matching swift-markdown's `SourceLocation.line`.
/// `endLine` is inclusive. A fraction of 0 stays on the block's first line, so a
/// block scrolled to its start round-trips to the same line.
public enum ReadingLineMap {
    public static func blockStart(containing line: Int, starts: [Int]) -> Int? {
        guard line > 0 else { return nil }
        var chosen: Int?
        for start in starts where start > 0 && start <= line {
            if chosen == nil || start > chosen! {
                chosen = start
            }
        }
        return chosen
    }

    public static func sourceLine(startLine: Int, endLine: Int, fraction: Double) -> Int {
        let start = max(1, startLine)
        let end = max(start, endLine)
        let clamped = min(1, max(0, fraction))
        if clamped == 0 || start == end { return start }
        let span = end - start
        let offset = Int((Double(span) * clamped).rounded(.down))
        return min(end, start + offset)
    }
}
