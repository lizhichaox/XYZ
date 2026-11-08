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

    /// Width of the fold column at the left of the numbers. Zero when nothing folds.
    static let foldColumnWidth: CGFloat = 14

    /// Only the fold chevrons take clicks; the rest of the gutter stays transparent to
    /// text selection.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let textView, textView.hasFoldableLines else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        guard local.x >= 0, local.x <= Self.foldColumnWidth else { return nil }
        return foldHeader(atY: local.y) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let line = foldHeader(atY: local.y), let textView else {
            super.mouseDown(with: event)
            return
        }
        textView.toggleFold(atLine: line)
    }

    private var hoveredLine: Int?

    private var foldTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let foldTrackingArea {
            removeTrackingArea(foldTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        foldTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let line = foldHeader(atY: local.y)
        guard line != hoveredLine else { return }
        hoveredLine = line
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredLine != nil else { return }
        hoveredLine = nil
        needsDisplay = true
    }

    /// The foldable header line at a vertical position, if any.
    private func foldHeader(atY y: CGFloat) -> Int? {
        guard let textView, textView.hasFoldableLines else { return nil }
        let state = textView.foldHeaderState()
        guard !state.isEmpty else { return nil }
        let rows = placedRows(textView: textView, lineCount: lineIndex().count).rows
        guard let row = rows.first(where: {
            $0.showsNumber && y >= $0.y && y <= $0.y + max($0.height, 1)
        }) else { return nil }
        return state[row.line] == nil ? nil : row.line
    }

    static func font(_ fontSize: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(10, (fontSize * 0.75).rounded()), weight: .regular)
    }

    /// The width the numbers need: at least two digits, so 1–9 do not jump. A file with
    /// foldable blocks gets one extra column at the left for the chevrons.
    func numberWidth(fontSize: CGFloat) -> CGFloat {
        let count = lineIndex().count
        let digits = max(2, String(count).count)
        let digit = ("0" as NSString).size(withAttributes: [.font: Self.font(fontSize)]).width
        let numbers = ceil(digit * CGFloat(digits))
        return numbers + (textView?.hasFoldableLines == true ? Self.foldColumnWidth : 0)
    }

    func invalidateLines() {
        cachedIndex = nil
        geometryKey = ""
        needsDisplay = true
    }

    /// Redraw only when the scroll, the line count, or the caret line changed.
    func noteGeometryChanged() {
        let origin = textView?.visibleRect.origin.y ?? -1
        let count = lineIndex().count
        let length = (textView?.string as NSString?)?.length ?? 0
        let caret = textView.map { lineIndex().line(at: min(max(0, $0.selectedRange().location), length)) } ?? 0
        let wrap = textView?.style.wraps == true
        let folds = textView?.foldableRanges.count ?? 0
        let folded = textView?.foldedHeaderLines.count ?? 0
        let key = "\(Int(origin.rounded())):\(count):\(caret):\(wrap):\(Int(bounds.height.rounded())):\(folds):\(folded)"
        guard key != geometryKey else { return }
        geometryKey = key
        needsDisplay = true
    }

    private var geometryKey = ""
    private var emptyPaintRetries = 0

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
        let highlight = LogicalLineGutter.highlighted(
            sourceLines: placed.rows.map(\.line),
            caret: caretLine
        )
        var drawn = 0
        var first = 0
        var last = 0
        var pairs: [String] = []
        let foldState = textView.foldHeaderState()
        for (index, row) in placed.rows.enumerated() {
            if row.y > bounds.maxY || row.y + row.height < 0 { continue }
            // A folded block has no visible rows: its lines compress onto the header, so
            // their numbers must not print there.
            if textView.isLineHidden(row.line) { continue }
            if highlight.indices.contains(index), highlight[index] {
                NSColor.xyzCurrentLine.setFill()
                NSRect(x: 0, y: row.y, width: bounds.width, height: max(row.height, 1)).fill()
            }
            guard row.showsNumber else { continue }
            if let folded = foldState[row.line], folded || row.line == hoveredLine {
                drawFoldChevron(folded: folded, row: row)
            }
            // Relative mode counts from the caret line; the caret line itself keeps the
            // absolute number so the reader can still see where they are.
            let relative = textView.style.relativeLineNumbers && row.line != caretLine
            let value = relative ? abs(row.line - caretLine) : row.line
            let label = String(value) as NSString
            let attributes = row.line == caretLine ? current : plain
            let width = ceil(label.size(withAttributes: attributes).width)
            let textHeight = font.ascender - font.descender
            let textY = row.y + max(0, (row.height - textHeight) / 2)
            let x = max(2, bounds.width - Self.gap - width)
            label.draw(at: NSPoint(x: x, y: textY), withAttributes: attributes)
            if drawn == 0 { first = row.line }
            last = row.line
            if pairs.count < 6 {
                pairs.append("\(row.line):\(Int(textY.rounded()))")
            }
            drawn += 1
        }
        if drawn == 0, lines.count > 0, textView.showsLineNumbers, emptyPaintRetries < 8 {
            emptyPaintRetries += 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.geometryKey = ""
                self.textView?.showViewport()
                self.needsDisplay = true
            }
        } else if drawn > 0 {
            emptyPaintRetries = 0
        }
        let path = textView.textLayoutManager == nil ? "textkit1" : "textkit2"
        XYZDiagnostics.gutterDraw(
            dirty: dirtyRect,
            bounds: bounds,
            lines: drawn,
            first: first,
            last: last,
            color: Self.colorDescription(plainColor),
            api: "\(placed.api) \(path)",
            pairs: pairs.joined(separator: ","),
            wrap: textView.style.wraps,
            mode: "editing"
        )
    }

    /// A small triangle in the fold column: pointing right when folded, down when open.
    private func drawFoldChevron(folded: Bool, row: Row) {
        let color = NSColor.xyzSecondaryText
        color.setFill()
        let side: CGFloat = 5
        let centerX = Self.foldColumnWidth / 2
        let centerY = row.y + row.height / 2
        let path = NSBezierPath()
        if folded {
            // ▶ closed
            path.move(to: NSPoint(x: centerX - side / 2, y: centerY - side))
            path.line(to: NSPoint(x: centerX + side, y: centerY))
            path.line(to: NSPoint(x: centerX - side / 2, y: centerY + side))
        } else {
            // ▼ open
            path.move(to: NSPoint(x: centerX - side, y: centerY - side / 2))
            path.line(to: NSPoint(x: centerX, y: centerY + side / 2))
            path.line(to: NSPoint(x: centerX + side, y: centerY - side / 2))
        }
        path.close()
        path.fill()
    }

    private struct Row {
        var line: Int
        /// False on a wrapped continuation. The number stays on the first visual row of the source line.
        var showsNumber: Bool
        var y: CGFloat
        var height: CGFloat
    }

    /// Visual rows from TextKit. A uniform line box is only valid when wrapping is off:
    /// with wrapping on, that box counts visual rows as source lines.
    private func placedRows(textView: XYZMacTextView, lineCount: Int) -> (rows: [Row], api: String) {
        let fragments = fragmentRows(textView: textView)
        let numbered = fragments.filter { $0.showsNumber && $0.y < bounds.maxY && $0.y + $0.height > 0 }
        if !numbered.isEmpty {
            return (fragments.filter { $0.y < bounds.maxY && $0.y + $0.height > 0 }, "textLineFragments")
        }
        // TextKit 1: line fragments are the truth, wrapping or not, and folding changes the
        // geometry a uniform line box cannot describe.
        if textView.textLayoutManager == nil, let laid = layoutManagerRows(textView: textView) {
            let numbered = laid.filter { $0.showsNumber && $0.y < bounds.maxY && $0.y + $0.height > 0 }
            if !numbered.isEmpty {
                return (laid.filter { $0.y < bounds.maxY && $0.y + $0.height > 0 }, "layoutManager")
            }
        }
        if textView.style.wraps {
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let laidOut = fragmentRows(textView: textView)
            let laidNumbered = laidOut.filter { $0.showsNumber && $0.y < bounds.maxY && $0.y + $0.height > 0 }
            if !laidNumbered.isEmpty {
                return (laidOut.filter { $0.y < bounds.maxY && $0.y + $0.height > 0 }, "textLineFragments")
            }
            if (textView.string as NSString).length == 0 {
                return ([emptyRow(textView: textView)], "empty-line")
            }
            return ([], "wrapped-unlaid")
        }
        return (lineBoxRows(textView: textView, lineCount: lineCount), "lineBox")
    }

    /// Headless check. Same rows `draw` uses, including ones scrolled just outside the clip.
    func testingSnapshot() -> (api: String, rows: [(line: Int, shows: Bool, y: CGFloat)]) {
        let count = lineIndex().count
        guard let textView else { return ("no-text-view", []) }
        let placed = placedRows(textView: textView, lineCount: count)
        let rows = placed.rows.map { (line: $0.line, shows: $0.showsNumber, y: $0.y) }
        return (placed.api, rows)
    }

    private func fragmentRows(textView: XYZMacTextView) -> [Row] {
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager else { return [] }
        let lines = lineIndex()
        let visible = textView.visibleRect
        let originY = textView.textContainerOrigin.y
        let documentStart = content.documentRange.location
        let start = manager.textViewportLayoutController.viewportRange?.location ?? documentStart
        var rows: [Row] = []
        var seen = 0
        var previousLine: Int?
        manager.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            seen += 1
            if seen > 400 { return false }
            let base = Self.documentOffset(of: fragment.rangeInElement.location, content: content, documentStart: documentStart)
            let lineFragments = fragment.textLineFragments
            if lineFragments.isEmpty {
                let line = lines.line(at: max(0, base))
                let shows = previousLine != line
                previousLine = line
                let frame = fragment.layoutFragmentFrame
                rows.append(Row(
                    line: line,
                    showsNumber: shows,
                    y: originY + frame.minY - visible.minY,
                    height: max(frame.height, 1)
                ))
                return true
            }
            let frame = fragment.layoutFragmentFrame
            let fragmentBase = base
            let fragmentLength = content.offset(
                from: fragment.rangeInElement.location,
                to: fragment.rangeInElement.endLocation
            )
            for lineFragment in lineFragments {
                let offset = Self.sourceOffset(
                    lineFragment: lineFragment,
                    fragmentBase: fragmentBase,
                    fragmentLength: fragmentLength
                )
                let line = lines.line(at: max(0, offset))
                let shows = previousLine != line
                previousLine = line
                let local = lineFragment.typographicBounds
                rows.append(Row(
                    line: line,
                    showsNumber: shows,
                    y: originY + frame.minY + local.minY - visible.minY,
                    height: max(local.height, 1)
                ))
            }
            return true
        }
        return rows
    }

    /// Document offset of a text location.
    private static func documentOffset(
        of location: NSTextLocation,
        content: NSTextContentManager,
        documentStart: NSTextLocation
    ) -> Int {
        content.offset(from: documentStart, to: location)
    }

    /// `characterRange` is either relative to this fragment or to the whole element.
    /// A range that fits inside the fragment is relative to the fragment. A range past
    /// that length is an index in the element, already included in `fragmentBase`.
    static func sourceOffset(lineFragment: NSTextLineFragment, fragmentBase: Int, fragmentLength: Int) -> Int {
        let range = lineFragment.characterRange
        if fragmentLength > 0, range.location + range.length <= fragmentLength {
            return fragmentBase + range.location
        }
        return range.location
    }

    /// Source lines from the layout manager that already draws the body. The first fragment
    /// of a newline line is numbered. A soft-wrapped continuation is not.
    ///
    /// Noncontiguous layout can report a later source line inside the visible band. When the
    /// visible numbers skip, measure once with contiguous layout and restore the flag. The
    /// text storage is left alone.
    private func layoutManagerRows(textView: XYZMacTextView) -> [Row]? {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        if (textView.string as NSString).length == 0 {
            return [emptyRow(textView: textView)]
        }
        let first = lineFragmentRows(textView: textView, layout: layout, container: container)
        if Self.isSourceRun(first) || first.isEmpty {
            return first
        }
        // A noncontiguous viewport can miss the first row of the visible band. Ask for the
        // whole document once (layout is cached afterwards) instead of toggling
        // `allowsNonContiguousLayout`: flipping that flag re-lays the note on every draw.
        let length = (textView.string as NSString).length
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
        return lineFragmentRows(textView: textView, layout: layout, container: container)
    }

    /// The box the source lines use. A number belongs to a source line, so it follows
    /// the text view's font and line height, not the smaller gutter typeface.
    private static func lineBox(for textView: XYZMacTextView) -> CGFloat {
        let font = textView.font ?? NSFont.systemFont(ofSize: textView.style.fontSize)
        return max(1, EditorTypography.paragraphStyle(textView.style, font: font).minimumLineHeight)
    }

    /// An empty note is one source line. Wrapping does not remove that number.
    private func emptyRow(textView: XYZMacTextView) -> Row {
        let box = Self.lineBox(for: textView)
        let visible = textView.visibleRect
        return Row(
            line: 1,
            showsNumber: true,
            y: textView.textContainerOrigin.y - visible.minY,
            height: box
        )
    }

    /// Visible numbers are a contiguous source run, and a wrapped note has a continuation row.
    private static func isSourceRun(_ rows: [Row]) -> Bool {
        let numbered = rows.filter(\.showsNumber).map(\.line)
        guard let first = numbered.first, !numbered.isEmpty else { return false }
        return numbered == Array(first..<(first + numbered.count))
    }

    /// Rows from the visible band only. The live editor is TextKit 1, and laying out the
    /// whole note on every gutter draw made scrolling and typing cost O(document): a
    /// 2,000-line note spent about 90 ms per draw. `allowsNonContiguousLayout` keeps the
    /// rest estimated, so only the band around the clip has to exist.
    private func lineFragmentRows(
        textView: XYZMacTextView,
        layout: NSLayoutManager,
        container: NSTextContainer
    ) -> [Row] {
        let ns = textView.string as NSString
        let length = ns.length
        guard length > 0 else { return [] }
        let visible = textView.visibleRect
        let padding = max(0, visible.height)
        let band = visible.insetBy(dx: 0, dy: -padding)
        layout.ensureLayout(forBoundingRect: band, in: container)
        let glyphs = layout.glyphRange(forBoundingRect: band, in: container)
        guard glyphs.length > 0 else { return [] }
        let lines = lineIndex()
        let origin = textView.textContainerOrigin
        var rows: [Row] = []
        var previous: Int?
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            guard glyphRange.length > 0 else { return }
            let index = layout.characterIndexForGlyph(at: glyphRange.location)
            let line = lines.line(at: max(0, min(index, length)))
            // The first fragment of a source line carries the number; its wrapped
            // continuations start past the line start. This also works when the band
            // starts in the middle of a wrapped line.
            let shows = line >= 1 && line <= lines.starts.count && index == lines.starts[line - 1]
            previous = line
            let top = origin.y + rect.minY
            guard top + rect.height > visible.minY - 1, top < visible.maxY + 1 else { return }
            rows.append(Row(
                line: line,
                showsNumber: shows,
                y: top - visible.minY,
                height: max(rect.height, 1)
            ))
        }
        // A note ending in a newline has one more empty line, reported as the extra line
        // fragment. It needs its number, especially while the caret can sit on it. Only
        // ask for it when the band reaches the bottom of the document.
        if visible.maxY >= textView.frame.height - 1,
           layout.extraLineFragmentTextContainer != nil,
           previous != lines.count {
            let rect = layout.extraLineFragmentRect
            let top = origin.y + rect.minY
            if top + rect.height > visible.minY - 1, top < visible.maxY + 1 {
                rows.append(Row(
                    line: lines.count,
                    showsNumber: true,
                    y: top - visible.minY,
                    height: max(rect.height, 1)
                ))
            }
        }
        return rows
    }

    /// Same line box the editor uses for source. Does not ask TextKit for fragment frames.
    private func lineBoxRows(textView: XYZMacTextView, lineCount: Int) -> [Row] {
        let box = Self.lineBox(for: textView)
        let visible = textView.visibleRect
        let originY = textView.textContainerOrigin.y
        let first = max(1, Int(floor((visible.minY - originY) / box)) + 1)
        let last = min(lineCount, max(first, Int(ceil((visible.maxY - originY) / box)) + 1))
        var rows: [Row] = []
        rows.reserveCapacity(max(0, last - first + 1))
        for line in first...last {
            let y = originY + CGFloat(line - 1) * box - visible.minY
            rows.append(Row(line: line, showsNumber: true, y: y, height: box))
        }
        return rows
    }

    private static func colorDescription(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "unresolved" }
        return String(format: "%.2f,%.2f,%.2f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }
}
#endif
