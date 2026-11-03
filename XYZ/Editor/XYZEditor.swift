import os
import SwiftUI
import XYZCore

/// Scroll anchors for a Source/Reading toggle. Category `viewmode`. Line numbers only.
enum ViewAnchorLog {
    static let logger = Logger(subsystem: "com.lizhichao.XYZ", category: "viewmode")

    static func captured(from mode: String, line: Int) {
        logger.notice("anchor from=\(mode, privacy: .public) line=\(line, privacy: .public)")
    }

    static func aligned(to mode: String, requested: Int, landed: Int) {
        logger.notice("align to=\(mode, privacy: .public) requested=\(requested, privacy: .public) landed=\(landed, privacy: .public)")
    }
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Visual defaults for the Markdown editor.
///
/// The default face is the system font (SF Pro, with PingFang SC for Chinese).
/// Settings choose a monospaced face (`monospacedKey`), the text size (`fontSizeKey`, shared
/// with Reading), and whether lines stop at a readable length (`readableWidthKey`).
struct XYZEditorStyle: Equatable {
    var fontSize: CGFloat = 16
    /// Line box height relative to the font size. Markdown source stores a hard return
    /// on every line, so this is a minimum line height rather than spacing between wraps.
    var lineHeight: CGFloat = 1.7
    var horizontalInset: CGFloat = 13
    var verticalInset: CGFloat = 8
    var monospaced: Bool = false
    /// `system`, `sfmono`, `menlo`, or `jetbrains`.
    var latin: String = "system"
    /// `pingfang`, `songti`, or `heiti`.
    var cjk: String = "pingfang"
    var readableWidth: Bool = false
    /// Long lines break to the editor width. Off scrolls sideways.
    var wraps: Bool = true

    /// A small fixed side margin. Line numbers widen the left side on their own.
    static func sideInset(for paneWidth: CGFloat) -> CGFloat {
        _ = paneWidth
        return 13
    }

    /// With a readable width, wide panes add padding so a line holds about 42 em: 42 Chinese
    /// characters, or 80 to 90 Latin ones. Reading uses the same measure.
    func sideInset(for paneWidth: CGFloat) -> CGFloat {
        let base = Self.sideInset(for: paneWidth)
        guard readableWidth else { return base }
        let measure = (fontSize * Self.readableEms).rounded()
        return max(base, floor((paneWidth - measure) / 2))
    }

    static let readableEms: CGFloat = 42
    static let monospacedKey = "xyz.editor.monospaced"
    static let fontSizeKey = "xyz.text.size"
    static let lineSpacingKey = "xyz.text.lineSpacing"
    static let latinFontKey = "xyz.text.font.latin"
    static let cjkFontKey = "xyz.text.font.cjk"
    static let readableWidthKey = "xyz.text.readableWidth"
    /// Line numbers beside Source. On unless turned off.
    static let lineNumbersKey = "xyz.editor.lineNumbers"
    /// Line numbers while reading. Off unless turned on. Editing always shows them.
    static let readingLineNumbersKey = "xyz.editor.readingLineNumbers"
    /// Break long lines to the editor width. On unless turned off.
    static let wordWrapKey = "xyz.editor.wordWrap"
    static let defaultFontSize: Double = 16
    static let fontSizes: ClosedRange<Double> = 11...24
    static let defaultLineSpacing: Double = 1.7
    static let lineSpacings: ClosedRange<Double> = 1.0...2.0
    static let markdown = XYZEditorStyle()

    static func clampedFontSize(_ size: Double) -> Double {
        min(fontSizes.upperBound, max(fontSizes.lowerBound, size.rounded()))
    }

    static func clampedLineSpacing(_ spacing: Double) -> Double {
        let tenths = (spacing * 10).rounded() / 10
        return min(lineSpacings.upperBound, max(lineSpacings.lowerBound, tenths))
    }

    static func latinIsMono(_ id: String) -> Bool {
        id == "sfmono" || id == "menlo" || id == "jetbrains"
    }

    func paragraphStyle(naturalLineHeight: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let target = max(naturalLineHeight, (fontSize * lineHeight).rounded(.up))
        paragraph.minimumLineHeight = target
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        paragraph.hyphenationFactor = 0
        return paragraph
    }
}

/// Commands the text view can perform.
///
/// `replaceContents` is used for programmatic reloads. Find/replace can grow this set
/// without changing the platform text views' public surface.
enum XYZEditorCommand: Equatable {
    case replaceContents(String)
}

/// Shared control surface for the macOS and iOS text views.
///
/// Both views are TextKit 2 (`NSTextLayoutManager`). Syntax highlighting can attach
/// to `textLayoutManager` later; large-file work can switch `onTextChange` from a full-string
/// push to a dirty-range signal and pull `text` when a snapshot or preview is due.
@MainActor
protocol XYZTextEditing: AnyObject {
    var text: String { get }
    var textLayoutManager: NSTextLayoutManager? { get }
    func perform(_ command: XYZEditorCommand)
}

/// Holds the scroll position to restore after Source and Reading trade places.
@MainActor
final class EditorScrollLink {
    var capture: () -> EditorScrollAnchor = { EditorScrollAnchor(fraction: 0, probe: "") }
    /// Go to Heading. The surface on screen (the editor or Reading) sets this when it updates.
    var revealLine: (Int) -> Void = { _ in }
    /// The source line at the top of Reading. Editing does not call this.
    var onViewportLine: ((Int) -> Void)?
    /// A search hit. The source editor selects the matched text on that line.
    var revealMatch: ((Int, String) -> Void)?
    /// Go to Line. The source editor sets this. Reading does not.
    var revealPosition: (Int, Int) -> Void = { _, _ in }
    private var pending: (anchor: EditorScrollAnchor, destination: EditorViewMode)?

    private struct QueuedCaret {
        var line: Int
        var column: Int
        var editorOnly: Bool
        var needle: String?
    }

    private var queuedReveal: QueuedCaret?

    /// Remember a source line to show once the editor for that file is on screen.
    /// `editorOnly` keeps Reading from consuming a Go to Line request.
    func storeQueuedReveal(_ line: Int, column: Int = 1, editorOnly: Bool = false, needle: String? = nil) {
        queuedReveal = QueuedCaret(line: line, column: max(1, column), editorOnly: editorOnly, needle: needle)
    }

    func takeQueuedReveal() -> Int? {
        guard let queued = queuedReveal, !queued.editorOnly else { return nil }
        queuedReveal = nil
        return queued.line
    }

    func takeQueuedEditorReveal() -> (line: Int, column: Int, needle: String?)? {
        guard let queued = queuedReveal else { return nil }
        queuedReveal = nil
        return (queued.line, queued.column, queued.needle)
    }

    func clearQueuedReveal() {
        queuedReveal = nil
    }

    var focusEditor: (() -> Void)?

    @discardableResult
    func noteToggle(to destination: EditorViewMode, fallbackLine: Int = 0) -> Int {
        var anchor = capture()
        if anchor.line <= 1, fallbackLine > 1 {
            anchor = EditorScrollAnchor(fraction: anchor.fraction, probe: "", line: fallbackLine)
        }
        pending = (anchor, destination)
        return anchor.line
    }

    func take(for destination: EditorViewMode) -> EditorScrollAnchor? {
        guard pending?.destination == destination else { return nil }
        let anchor = pending?.anchor
        pending = nil
        return anchor
    }
}

/// Plain-text Markdown editor.
///
/// `text` is the buffer to show when the platform view is created. Later keystrokes stay in
/// the text view and are reported through `onTextChange`. Pass the document scene's undo
/// manager so typing participates in save/dirty tracking.
struct XYZEditor: View {
    var text: String
    var isEditable: Bool
    var undoManager: UndoManager?
    /// Bump this to replace the buffer from outside the text view, such as a disk reload.
    var reloadToken: Int = 0
    var scrollLink: EditorScrollLink
    /// Markdown styling and list continuation. Other files are plain text.
    var markup: Bool = true
    /// Continuous spell checking, for prose rather than config files and code.
    var spellCheck: Bool = true
    /// Plain coloring for code and structured text. Markdown keeps `markup`.
    var syntax: SyntaxLanguage = .plain
    /// Code uses a fixed-width face even when the prose setting is proportional.
    var forcesMonospace: Bool = false
    var onSelection: ((EditorCaret) -> Void)? = nil
    var onTextChange: (String) -> Void
    #if os(macOS)
    /// When set, this wins over the Reading line-number setting. Editing passes true.
    var lineNumbersVisible: Bool? = nil
    var find: EditorFindModel? = nil
    #endif

    @AppStorage(XYZEditorStyle.monospacedKey) private var monospaced = false
    @AppStorage(XYZEditorStyle.fontSizeKey) private var fontSize = XYZEditorStyle.defaultFontSize
    @AppStorage(XYZEditorStyle.lineSpacingKey) private var lineSpacing = XYZEditorStyle.defaultLineSpacing
    @AppStorage(XYZEditorStyle.latinFontKey) private var latinFont = "system"
    @AppStorage(XYZEditorStyle.cjkFontKey) private var cjkFont = "pingfang"
    @AppStorage(XYZEditorStyle.readableWidthKey) private var readableWidth = false
    @AppStorage(XYZEditorStyle.lineNumbersKey) private var lineNumbers = true
    #if os(macOS)
    @AppStorage(XYZEditorStyle.wordWrapKey) private var wordWrap = true
    #endif

    var body: some View {
        #if os(macOS)
        XYZMacEditor(
            text: text,
            isEditable: isEditable,
            undoManager: undoManager,
            reloadToken: reloadToken,
            style: XYZEditorStyle(
                fontSize: CGFloat(XYZEditorStyle.clampedFontSize(fontSize)),
                lineHeight: CGFloat(XYZEditorStyle.clampedLineSpacing(lineSpacing)),
                monospaced: monospaced || forcesMonospace || XYZEditorStyle.latinIsMono(latinFont),
                latin: latinFont == "system" && monospaced ? "sfmono" : latinFont,
                cjk: cjkFont,
                readableWidth: readableWidth,
                wraps: wordWrap
            ),
            scrollLink: scrollLink,
            markup: markup,
            spellCheck: spellCheck,
            syntax: syntax,
            lineNumbers: lineNumbersVisible ?? false,
            find: find,
            onSelection: onSelection,
            onTextChange: onTextChange
        )
        #else
        XYZIOSEditor(
            text: text,
            isEditable: isEditable,
            undoManager: undoManager,
            reloadToken: reloadToken,
            monospaced: monospaced || forcesMonospace,
            scrollLink: scrollLink,
            markup: markup,
            onTextChange: onTextChange
        )
        #endif
    }
}

extension Color {
    static var editorBackground: Color {
        #if os(macOS)
        Color(nsColor: .xyzEditor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Sidebar and status bar. Light is white, the same as the editor. Dark is a step under it.
    static var sidebarBackground: Color {
        #if os(macOS)
        Color(nsColor: .xyzSidebar)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    #if os(macOS)
    static var xyzAccent: Color { Color(nsColor: .xyzAccent) }
    static var xyzInk: Color { Color(nsColor: .xyzInk) }
    static var xyzSecondaryText: Color { Color(nsColor: .xyzSecondaryText) }
    static var xyzSelection: Color { Color(nsColor: .xyzSelection) }
    static var xyzDivider: Color { Color(nsColor: .xyzDivider) }
    #endif
}

#if os(macOS)
extension NSColor {
    /// One light theme and one dark theme. Accent is the divider hover blue, used sparingly.
    static func xyzDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func xyzSRGB(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

    /// Editor and Reading canvas. Light `#FFFFFF`, dark `#1E1E1E`.
    static var xyzEditor: NSColor {
        xyzDynamic(light: xyzSRGB(255, 255, 255), dark: xyzSRGB(30, 30, 30))
    }

    /// Sidebars, the status bar, and the title-bar field in light mode.
    /// Light is white (`#FFFFFF`), the same as the editor. Dark stays `#181818`.
    /// Hairlines separate those areas. There is no grey sidebar fill.
    static var xyzSidebar: NSColor {
        xyzDynamic(light: xyzSRGB(255, 255, 255), dark: xyzSRGB(24, 24, 24))
    }

    /// Body text. Light `#1F1F1F`, dark `#D4D4D4`.
    static var xyzInk: NSColor {
        xyzDynamic(light: xyzSRGB(31, 31, 31), dark: xyzSRGB(212, 212, 212))
    }

    /// Tree, breadcrumbs, status, gutter. Light `#5F6368`, dark `#9D9D9D`.
    static var xyzSecondaryText: NSColor {
        xyzDynamic(light: xyzSRGB(95, 99, 104), dark: xyzSRGB(157, 157, 157))
    }

    /// Divider hover and the few accent marks. `#0078D4` (passes WCAG AA on white).
    static var xyzAccent: NSColor {
        xyzSRGB(0, 120, 212)
    }

    /// Selected row. Accent at 14% with ink text. Not a grey slab.
    static var xyzSelection: NSColor {
        xyzAccent.withAlphaComponent(0.14)
    }

    /// Find matches. Light stays an accent tint. Dark uses a visible orange.
    static var xyzFindMatch: NSColor {
        xyzDynamic(
            light: xyzAccent.withAlphaComponent(0.16),
            dark: NSColor(srgbRed: 234 / 255, green: 92 / 255, blue: 0, alpha: 0.50)
        )
    }

    /// The current find match. Dark is a stronger orange so it reads on `#1E1E1E`.
    static var xyzFindCurrent: NSColor {
        xyzDynamic(
            light: xyzAccent.withAlphaComponent(0.42),
            dark: NSColor(srgbRed: 234 / 255, green: 92 / 255, blue: 0, alpha: 0.92)
        )
    }

    /// Pressed find toggles. Light keeps the quiet accent tint. Dark is solid accent.
    static var xyzFindToggleFill: NSColor {
        xyzDynamic(light: xyzAccent.withAlphaComponent(0.14), dark: xyzAccent)
    }

    static var xyzFindToggleInk: NSColor {
        xyzDynamic(light: xyzAccent, dark: NSColor.white)
    }

    /// Hairline between white surfaces. Light `#E5E5E5`, dark `#2B2B2B`.
    static var xyzDivider: NSColor {
        xyzDynamic(light: xyzSRGB(229, 229, 229), dark: xyzSRGB(43, 43, 43))
    }

    /// Editing's current line. Light is accent at 6%. Dark keeps the quiet ink band.
    static var xyzCurrentLine: NSColor {
        xyzDynamic(
            light: xyzSRGB(0, 120, 212).withAlphaComponent(0.06),
            dark: xyzSRGB(212, 212, 212).withAlphaComponent(0.08)
        )
    }
}

/// White in light mode, the editor color in dark, with a hairline and the panel's shadow.
final class PopupSurface: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.xyzEditor.cgColor
            layer?.borderColor = NSColor.xyzDivider.cgColor
        }
    }
}
#endif
