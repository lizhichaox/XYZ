#if os(macOS)
import AppKit
import XYZCore

/// Line numbers in the editor's left padding, right-aligned against the text.
///
/// The gutter is a subview of the scroll view, above the clip view. TextKit 2 draws line
/// fragments as subviews of the text view, and those cover a gutter that lives inside it.
/// Fragments come from `textLayoutManager`, not from `layoutManager` (TextKit 1), which is nil here.
final class LineNumberGutter: NSView {
    weak var textView: XYZMacTextView?
    private var index: LineIndex?

    /// Space between the numbers and the text.
    static let gap: CGFloat = 12

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

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

    /// Pins the gutter over the visible left edge of `scrollView`.
    func place(on scrollView: NSScrollView, width: CGFloat) {
        if superview !== scrollView {
            removeFromSuperview()
            scrollView.addSubview(self, positioned: .above, relativeTo: scrollView.contentView)
        }
        let visible = scrollView.contentView.frame
        // Leave a column of text uncovered. A gutter as wide as the clip paints a blank editor.
        let room = max(visible.width - 24, 28)
        let column = min(max(width, 28), room)
        clipsToBounds = true
        let next = NSRect(
            x: visible.minX,
            y: visible.minY,
            width: column,
            height: max(visible.height, 1)
        )
        if frame != next {
            frame = next
        }
        isHidden = false
    }

    private func lineIndex() -> LineIndex {
        if let index { return index }
        if let cached = textView?.cachedLineIndex() {
            index = cached
            return cached
        }
        let built = LineIndex(textView?.string ?? "")
        index = built
        return built
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let textView,
              let manager = textView.textLayoutManager,
              let content = manager.textContentManager,
              bounds.width > 1, bounds.height > 1 else { return }
        let lines = lineIndex()
        guard lines.count > 0 else { return }
        let font = Self.font(textView.style.fontSize)
        let caretLine = lines.line(at: textView.selectedRange().location)
        let origin = textView.textContainerOrigin
        let scrollY = textView.visibleRect.minY
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        guard let start = visibleStart(manager: manager, origin: origin, scrollY: scrollY) else { return }
        let right = bounds.width - Self.gap
        var seen = 0
        manager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            seen += 1
            if seen > 400 { return false }
            let fragmentFrame = fragment.layoutFragmentFrame
            let top = origin.y + fragmentFrame.minY - scrollY
            if top > bounds.maxY { return false }
            if top + fragmentFrame.height < 0 { return true }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let line = lines.line(at: offset)
            let baseline: CGFloat
            if let first = fragment.textLineFragments.first {
                baseline = top + first.typographicBounds.minY + first.glyphOrigin.y
            } else {
                baseline = top + font.ascender
            }
            if line == caretLine {
                NSColor.labelColor.withAlphaComponent(0.045).setFill()
                NSRect(x: 0, y: top, width: bounds.width, height: fragmentFrame.height).fill()
            }
            let label = String(line) as NSString
            let attributes = line == caretLine ? current : plain
            let width = label.size(withAttributes: attributes).width
            let point = NSPoint(x: right - width, y: baseline - font.ascender)
            if point.y < bounds.maxY && point.y + font.ascender > bounds.minY - font.descender {
                label.draw(at: point, withAttributes: attributes)
            }
            return true
        }
    }

    /// The first fragment on screen. Lays out only that screen, not the rest of a large file.
    private func visibleStart(manager: NSTextLayoutManager, origin: CGPoint, scrollY: CGFloat) -> NSTextLocation? {
        let viewport = manager.textViewportLayoutController
        viewport.layoutViewport()
        if let location = viewport.viewportRange?.location {
            return location
        }
        guard let content = manager.textContentManager else { return nil }
        let height = max(bounds.height, 1)
        let rect = CGRect(x: 0, y: max(0, scrollY - origin.y), width: max(bounds.width, 1), height: height)
        manager.ensureLayout(for: rect)
        return content.documentRange.location
    }
}
#endif
