#if os(macOS)
import AppKit
import XYZCore

/// Line numbers beside the editor, as a sibling of the scroll view.
///
/// `NSScrollView` lays out only its clip view and scrollers. A gutter added inside it
/// is covered by the clip view, so the numbers never appear. This view sits next to
/// the scroller and redraws when the clip view scrolls.
final class LineNumberGutter: NSView {
    weak var textView: XYZMacTextView?

    /// Space between the numbers and the text.
    static let gap: CGFloat = 8

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    static func font(_ fontSize: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(10, (fontSize * 0.75).rounded()), weight: .regular)
    }

    /// The width the numbers need: at least two digits, so 1–9 do not jump.
    func numberWidth(fontSize: CGFloat) -> CGFloat {
        let count = lineIndex().count
        let digits = max(2, String(count).count)
        let digit = ("0" as NSString).size(withAttributes: [.font: Self.font(fontSize)]).width
        return ceil(digit * CGFloat(digits))
    }

    func invalidateLines() {
        cachedIndex = nil
        needsDisplay = true
    }

    private var cachedIndex: LineIndex?

    private func lineIndex() -> LineIndex {
        if let cachedIndex { return cachedIndex }
        if let cached = textView?.cachedLineIndex() {
            cachedIndex = cached
            return cached
        }
        let built = LineIndex(textView?.string ?? "")
        cachedIndex = built
        return built
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let textView, bounds.width > 2, bounds.height > 2 else { return }
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { return }
        let lines = lineIndex()
        guard lines.count > 0 else { return }
        let font = Self.font(textView.style.fontSize)
        let lineHeight = font.ascender - font.descender
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let length = (textView.string as NSString).length
        let caretLine = lines.line(at: min(max(0, textView.selectedRange().location), length))
        let plain: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let current: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        // Use whatever is already laid out. Laying out from here during draw clears the viewport.
        let start = manager.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        var seen = 0
        manager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            seen += 1
            if seen > 400 { return false }
            let frame = fragment.layoutFragmentFrame
            let y = origin.y + frame.minY - visible.minY
            if y > bounds.maxY { return false }
            if y + frame.height < 0 { return true }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let line = lines.line(at: max(0, offset))
            if line == caretLine {
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: max(frame.height, 1)).fill()
            }
            let label = String(line) as NSString
            let attributes = line == caretLine ? current : plain
            let width = ceil(label.size(withAttributes: attributes).width)
            let textY = y + max(0, (frame.height - lineHeight) / 2)
            let x = max(4, bounds.width - Self.gap - width)
            label.draw(at: NSPoint(x: x, y: textY), withAttributes: attributes)
            return true
        }
    }
}
#endif
