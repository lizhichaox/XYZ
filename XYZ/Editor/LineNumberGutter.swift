#if os(macOS)
import AppKit
import XYZCore

/// Line numbers in the editor's left padding, right-aligned against the text.
///
/// One number per source line; a wrapped line keeps its number on its first row. The view is a
/// subview of the text view, so it scrolls with the text and draws only the rows in view. Each
/// TextKit 2 layout fragment is a paragraph, which is a source line, so the number sits on the
/// baseline of the fragment's first line. The caret's line is a shade darker.
final class LineNumberGutter: NSView {
    weak var textView: XYZMacTextView?
    private var index: LineIndex?

    /// Space between the numbers and the text.
    static let gap: CGFloat = 12

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    static func font(_ fontSize: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(10, (fontSize * 0.75).rounded()), weight: .regular)
    }

    /// The text changed. Returns true when the widest number gained or lost a digit.
    @discardableResult
    func invalidateLines() -> Bool {
        let digits = index.map { String($0.count).count }
        index = nil
        needsDisplay = true
        return digits != String(lineIndex().count).count
    }

    /// The width the numbers need: at least three digits, so a growing note does not shift.
    func numberWidth(fontSize: CGFloat) -> CGFloat {
        let digits = max(3, String(lineIndex().count).count)
        let digit = ("0" as NSString).size(withAttributes: [.font: Self.font(fontSize)]).width
        return ceil(digit * CGFloat(digits))
    }

    private func lineIndex() -> LineIndex {
        if let index { return index }
        let built = LineIndex(textView?.string ?? "")
        index = built
        return built
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { return }
        let lines = lineIndex()
        let font = Self.font(textView.style.fontSize)
        let caretLine = lines.line(at: textView.selectedRange().location)
        let origin = textView.textContainerOrigin
        let right = textView.textContainerInset.width - Self.gap
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        // This view shares the text view's coordinates. Layout fragments use the container's.
        let top = CGPoint(x: 0, y: max(0, dirtyRect.minY - origin.y))
        let start = manager.textLayoutFragment(for: top)?.rangeInElement.location ?? content.documentRange.location
        manager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > dirtyRect.maxY { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let line = lines.line(at: offset)
            let baseline: CGFloat
            if let first = fragment.textLineFragments.first {
                baseline = origin.y + frame.minY + first.typographicBounds.minY + first.glyphOrigin.y
            } else {
                baseline = origin.y + frame.minY + font.ascender
            }
            let label = String(line) as NSString
            let attributes = line == caretLine ? current : plain
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: right - width, y: baseline - font.ascender), withAttributes: attributes)
            return true
        }
    }
}
#endif
