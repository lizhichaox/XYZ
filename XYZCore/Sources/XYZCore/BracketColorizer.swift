import Foundation

/// One bracket character and its nesting depth. Depth zero is the outermost pair.
public struct BracketSpan: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var depth: Int

    public init(location: Int, length: Int, depth: Int) {
        self.location = location
        self.length = length
        self.depth = depth
    }
}

/// Finds brackets outside strings and comments so the editor can color them by depth.
public enum BracketColorizer {
    public static func spans(in text: String, excluding excluded: [Range<Int>] = []) -> [BracketSpan] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let ranges = merged(excluded)
        var result: [BracketSpan] = []
        var stack: [UInt16] = []
        var location = 0
        var excludedIndex = 0
        while location < ns.length {
            while excludedIndex < ranges.count, ranges[excludedIndex].upperBound <= location {
                excludedIndex += 1
            }
            if excludedIndex < ranges.count,
               ranges[excludedIndex].lowerBound <= location,
               location < ranges[excludedIndex].upperBound {
                location = ranges[excludedIndex].upperBound
                continue
            }
            let unit = ns.character(at: location)
            switch unit {
            case 0x28, 0x5B, 0x7B:
                result.append(BracketSpan(location: location, length: 1, depth: stack.count))
                stack.append(unit)
            case 0x29, 0x5D, 0x7D:
                if let open = stack.last, closes(open, unit) {
                    stack.removeLast()
                    result.append(BracketSpan(location: location, length: 1, depth: stack.count))
                }
            default:
                break
            }
            location += 1
        }
        return result
    }

    private static func closes(_ open: UInt16, _ close: UInt16) -> Bool {
        switch open {
        case 0x28: return close == 0x29
        case 0x5B: return close == 0x5D
        case 0x7B: return close == 0x7D
        default: return false
        }
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<Int>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
