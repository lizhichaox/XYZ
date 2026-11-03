import Foundation

/// Line numbers beside wrapped text.
///
/// A source line keeps one number, on its first visual row. Wrapped continuations
/// stay blank. Reading uses the same split for a rendered block that covers several
/// source lines.
public enum LogicalLineGutter {
    /// `fragmentOffsets` are UTF-16 starts of visual rows, in order.
    /// The first row of each logical line shows that line. Later rows of the same line are nil.
    public static func labels(text: String, fragmentOffsets: [Int]) -> [Int?] {
        let index = LineIndex(text)
        var previous: Int?
        return fragmentOffsets.map { offset in
            let line = index.line(at: max(0, offset))
            if previous == line { return nil }
            previous = line
            return line
        }
    }

    /// Which visual rows belong to the caret's logical line.
    public static func highlighted(sourceLines: [Int], caret: Int) -> [Bool] {
        sourceLines.map { $0 == caret }
    }

    /// Labels for Editing. Fragment lines mark wrapped continuations blank.
    /// With no fragments, every source line is labeled, including line 1. Never empty.
    public static func editingLabels(text: String, fragmentLines: [Int]?) -> [Int?] {
        if let fragmentLines, !fragmentLines.isEmpty {
            var previous: Int?
            return fragmentLines.map { raw in
                let line = max(1, raw)
                if previous == line { return nil }
                previous = line
                return line
            }
        }
        let count = max(1, LineIndex(text).count)
        return (1...count).map { Optional($0) }
    }

    public struct ReadingLabel: Equatable, Sendable {
        public var line: Int
        public var y: CGFloat

        public init(line: Int, y: CGFloat) {
            self.line = line
            self.y = y
        }
    }

    /// One number per rendered block, at that block's top.
    /// A label that would not sit strictly below the previous one is skipped.
    public static func placedReading(blocks: [(line: Int, y: CGFloat)], minimumGap: CGFloat) -> [ReadingLabel] {
        var placed: [ReadingLabel] = []
        let gap = max(0, minimumGap)
        for block in blocks where block.line > 0 {
            if let last = placed.last, block.y < last.y + gap {
                continue
            }
            placed.append(ReadingLabel(line: block.line, y: block.y))
        }
        return placed
    }

    /// One rendered block. `start` and `end` are inclusive 1-based source lines.
    public struct Block: Equatable, Sendable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    /// Labels for rendered blocks. `visualRows[i]` is how many wrapped rows block `i` occupies.
    /// A block that spans source lines shows each of those lines. Extra rows are blank continuations.
    public static func readingLabels(blocks: [Block], visualRows: [Int]) -> [Int?] {
        let count = min(blocks.count, visualRows.count)
        var rows: [Int?] = []
        rows.reserveCapacity(visualRows.reduce(0, +))
        for index in 0..<count {
            rows.append(contentsOf: blockLabels(
                start: blocks[index].start,
                end: blocks[index].end,
                visualRows: visualRows[index]
            ))
        }
        return rows
    }

    /// One block. Fewer visual rows than source lines shows the leading source lines, one each.
    /// More visual rows spreads the extra blank rows across those source lines, front first.
    public static func blockLabels(start: Int, end: Int, visualRows: Int) -> [Int?] {
        guard visualRows > 0 else { return [] }
        let first = max(1, start)
        let last = max(first, end)
        let logical = last - first + 1
        if visualRows <= logical {
            return (0..<visualRows).map { first + $0 }
        }
        let extra = visualRows - logical
        let share = extra / logical
        var remainder = extra % logical
        var rows: [Int?] = []
        rows.reserveCapacity(visualRows)
        for offset in 0..<logical {
            rows.append(first + offset)
            var blanks = share
            if remainder > 0 {
                blanks += 1
                remainder -= 1
            }
            for _ in 0..<blanks {
                rows.append(nil)
            }
        }
        return rows
    }
}

/// Where to put the clip so a find match is on screen, with a margin.
public enum FindScroll {
    /// Centers the match when it sits outside the margin. A match already inside stays put.
    public static func origin(
        matchMin: CGFloat,
        matchMax: CGFloat,
        visibleOrigin: CGFloat,
        visibleLength: CGFloat,
        contentLength: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        let length = max(1, visibleLength)
        let pad = min(max(0, margin), length / 4)
        let maxOrigin = max(0, contentLength - length)
        let origin = min(max(0, visibleOrigin), maxOrigin)
        let viewMin = origin + pad
        let viewMax = origin + length - pad
        if matchMin >= viewMin && matchMax <= viewMax {
            return origin
        }
        let matchHeight = max(1, matchMax - matchMin)
        let centered = matchMin - (length - matchHeight) / 2
        return min(max(0, centered), maxOrigin)
    }
}
