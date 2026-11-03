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
        NSColor.xyzEditor.setFill()
        dirtyRect.fill()
        guard let textView, bounds.width > 2, bounds.height > 2 else {
            XYZDiagnostics.gutterDraw(dirty: dirtyRect, bounds: bounds, lines: 0, first: 0, last: 0, color: "none", api: "no-text-view")
            return
        }
        let lines = lineIndex()
        guard lines.count > 0 else {
            XYZDiagnostics.gutterDraw(dirty: dirtyRect, bounds: bounds, lines: 0, first: 0, last: 0, color: "none", api: "empty")
            return
        }
        let font = Self.font(textView.style.fontSize)
        let length = (textView.string as NSString).length
        let caretLine = lines.line(at: min(max(0, textView.selectedRange().location), length))
        let plainColor = NSColor.xyzSecondaryText
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: plainColor]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.xyzInk]
        let placed = placedRows(textView: textView, lineCount: lines.count)
        var drawn = 0
        var first = 0
        var last = 0
        for row in placed.rows {
            if row.y > bounds.maxY || row.y + row.height < 0 { continue }
            if row.line == caretLine {
                NSColor.xyzInk.withAlphaComponent(0.08).setFill()
                NSRect(x: 0, y: row.y, width: bounds.width, height: max(row.height, 1)).fill()
            }
            let label = String(row.line) as NSString
            let attributes = row.line == caretLine ? current : plain
            let width = ceil(label.size(withAttributes: attributes).width)
            let textHeight = font.ascender - font.descender
            let textY = row.y + max(0, (row.height - textHeight) / 2)
            let x = max(2, bounds.width - Self.gap - width)
            label.draw(at: NSPoint(x: x, y: textY), withAttributes: attributes)
            if drawn == 0 { first = row.line }
            last = row.line
            drawn += 1
        }
        XYZDiagnostics.gutterDraw(
            dirty: dirtyRect,
            bounds: bounds,
            lines: drawn,
            first: first,
            last: last,
            color: Self.colorDescription(plainColor),
            api: placed.api
        )
    }

    private struct Row {
        var line: Int
        var y: CGFloat
        var height: CGFloat
    }

    /// Fragment frames when TextKit 2 has them. Otherwise one slot per source line from the line box.
    private func placedRows(textView: XYZMacTextView, lineCount: Int) -> (rows: [Row], api: String) {
        let fragments = fragmentRows(textView: textView)
        let visible = fragments.filter { $0.y < bounds.maxY && $0.y + $0.height > 0 }
        if !visible.isEmpty {
            return (visible, "textLayoutManager.enumerateTextLayoutFragments")
        }
        return (lineBoxRows(textView: textView, lineCount: lineCount), "lineBox")
    }

    private func fragmentRows(textView: XYZMacTextView) -> [Row] {
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { return [] }
        let lines = lineIndex()
        let visible = textView.visibleRect
        let originY = textView.textContainerOrigin.y
        let start = manager.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        var rows: [Row] = []
        var seen = 0
        manager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            seen += 1
            if seen > 400 { return false }
            let frame = fragment.layoutFragmentFrame
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let line = lines.line(at: max(0, offset))
            rows.append(Row(
                line: line,
                y: originY + frame.minY - visible.minY,
                height: max(frame.height, 1)
            ))
            return true
        }
        return rows
    }

    /// Same line box the editor uses for source. Does not ask TextKit for fragment frames.
    private func lineBoxRows(textView: XYZMacTextView, lineCount: Int) -> [Row] {
        let font = Self.font(textView.style.fontSize)
        let natural = font.ascender - font.descender + font.leading
        let box = max(1, textView.style.paragraphStyle(naturalLineHeight: natural).minimumLineHeight)
        let visible = textView.visibleRect
        let originY = textView.textContainerOrigin.y
        let first = max(1, Int(floor((visible.minY - originY) / box)) + 1)
        let last = min(lineCount, max(first, Int(ceil((visible.maxY - originY) / box)) + 1))
        var rows: [Row] = []
        rows.reserveCapacity(max(0, last - first + 1))
        for line in first...last {
            let y = originY + CGFloat(line - 1) * box - visible.minY
            rows.append(Row(line: line, y: y, height: box))
        }
        return rows
    }

    private static func colorDescription(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "unresolved" }
        return String(format: "%.2f,%.2f,%.2f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }
}
#endif
