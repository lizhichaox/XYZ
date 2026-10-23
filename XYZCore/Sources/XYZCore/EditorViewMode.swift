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
/// `fraction` is the distance down the document, from 0 to 1. `probe` is text from
/// the top visible line. A matching line near that fraction wins; otherwise the
/// fraction picks the line.
public struct EditorScrollAnchor: Equatable, Sendable {
    public var fraction: Double
    public var probe: String

    public init(fraction: Double, probe: String) {
        self.fraction = min(1, max(0, fraction))
        self.probe = probe
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

    /// UTF-16 offset of the line `lineIndex` points at.
    public func utf16Location(in text: String) -> Int {
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
