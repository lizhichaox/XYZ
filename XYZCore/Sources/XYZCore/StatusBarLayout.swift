import Foundation

/// One thing the bottom bar can show. The bar has a right-hand settings group and a
/// left-hand position group; an entry that does not fit on the right moves left.
public enum StatusBarEntry: Equatable, Sendable {
    case wrap
    case words(TextStatistics)
    case encoding(TextEncoding)
    case lineEnding(LineEnding)
    case detail(String)
    case mode(String)
}

/// The entries each half of the status bar shows, at most three per half.
public struct StatusBarLayout: Equatable, Sendable {
    public var left: [StatusBarEntry]
    public var right: [StatusBarEntry]

    public init(left: [StatusBarEntry], right: [StatusBarEntry]) {
        self.left = left
        self.right = right
    }
}

public enum StatusBarDistribution {
    public static let perSide = 3

    /// `candidates` is in display order and also in priority order for the right group:
    /// the trailing entries stay on the right (mode is last, so it always stays), the
    /// leading ones overflow to the left. The left group starts with the caret or reading
    /// progress and the selection, if any, and the overflow fills what is left.
    public static func layout(
        candidates: [StatusBarEntry],
        hasPrimary: Bool,
        hasSelection: Bool,
        perSide: Int = StatusBarDistribution.perSide
    ) -> StatusBarLayout {
        let capacity = max(0, perSide)
        let right = Array(candidates.suffix(capacity))
        let overflow = candidates.dropLast(right.count)
        let primary = (hasPrimary ? 1 : 0) + (hasSelection ? 1 : 0)
        let leftSlots = max(0, capacity - primary)
        return StatusBarLayout(left: Array(overflow.prefix(leftSlots)), right: right)
    }
}
