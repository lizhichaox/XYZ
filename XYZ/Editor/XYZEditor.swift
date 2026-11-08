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
/// Settings choose a monospaced face (`monospacedKey`) and the text size (`fontSizeKey`,
/// shared with Reading).
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
    /// Long lines break to the editor width. Off scrolls sideways.
    var wraps: Bool = true
    /// Gutter numbers count from the caret line instead of from the top.
    var relativeLineNumbers: Bool = false
    /// Spaces and tabs get a middle dot.
    var showsWhitespace: Bool = false

    /// A small fixed side margin. Line numbers widen the left side on their own.
    static func sideInset(for paneWidth: CGFloat) -> CGFloat {
        _ = paneWidth
        return 13
    }

    static let monospacedKey = "xyz.editor.monospaced"
    static let fontSizeKey = "xyz.text.size"
    static let lineSpacingKey = "xyz.text.lineSpacing"
    static let latinFontKey = "xyz.text.font.latin"
    static let cjkFontKey = "xyz.text.font.cjk"
    /// Line numbers beside Source. On unless turned off.
    static let lineNumbersKey = "xyz.editor.lineNumbers"
    /// Old Reading line-number preference. It is not read. Reading has no gutter.
    static let readingLineNumbersKey = "xyz.editor.readingLineNumbers"
    /// Break long lines to the editor width. On unless turned off.
    static let wordWrapKey = "xyz.editor.wordWrap"
    /// Gutter numbers count from the caret line. Off unless turned on.
    static let relativeLineNumbersKey = "xyz.editor.relativeLineNumbers"
    /// Spaces and tabs are drawn as dots. Off unless turned on.
    static let showWhitespaceKey = "xyz.editor.showWhitespace"
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

    func paragraphStyle(naturalLineHeight: CGFloat, spaceAdvance: CGFloat? = nil) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let target = max(naturalLineHeight, (fontSize * lineHeight).rounded(.up))
        paragraph.minimumLineHeight = target
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        paragraph.hyphenationFactor = 0
        if let spaceAdvance {
            // Match the editor's two-space indent guides and Reading's tab-size: 2.
            // AppKit's default 28pt stops are unrelated to the selected font or zoom.
            paragraph.tabStops = []
            paragraph.defaultTabInterval = max(1, spaceAdvance * 2)
        }
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
    /// How far down the page Reading is, as a whole percent. Published only when the
    /// number changes, so a scroll does not redraw the window on every frame.
    var onReadingProgress: ((Int) -> Void)?
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
    @AppStorage(XYZEditorStyle.lineNumbersKey) private var lineNumbers = true
    #if os(macOS)
    @AppStorage(XYZEditorStyle.wordWrapKey) private var wordWrap = true
    @AppStorage(XYZEditorStyle.relativeLineNumbersKey) private var relativeLineNumbers = false
    @AppStorage(XYZEditorStyle.showWhitespaceKey) private var showsWhitespace = false
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
                wraps: wordWrap,
                relativeLineNumbers: relativeLineNumbers,
                showsWhitespace: showsWhitespace
            ),
            scrollLink: scrollLink,
            markup: markup,
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
    convenience init(xyz color: XYZColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// One theme role, resolved per drawing appearance so every window repaints on a
    /// theme change. The palette lives in `XYZTheme`; nothing hard-codes a hex here.
    static func xyzResolved(_ role: KeyPath<XYZTheme, XYZColor>) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(xyz: XYZTheme.resolved(dark: dark)[keyPath: role])
        }
    }

    static var xyzEditor: NSColor { xyzResolved(\.editor) }
    static var xyzSidebar: NSColor { xyzResolved(\.sidebar) }
    static var xyzInk: NSColor { xyzResolved(\.ink) }
    static var xyzSecondaryText: NSColor { xyzResolved(\.secondaryText) }
    static var xyzTertiaryText: NSColor { xyzResolved(\.tertiaryText) }
    static var xyzAccent: NSColor { xyzResolved(\.accent) }
    static var xyzSelection: NSColor { xyzResolved(\.selection) }
    static var xyzSelectionText: NSColor { xyzResolved(\.selectionText) }
    static var xyzCurrentLine: NSColor { xyzResolved(\.currentLine) }
    static var xyzDivider: NSColor { xyzResolved(\.divider) }
    static var xyzHover: NSColor { xyzResolved(\.hover) }
    static var xyzDisabledTint: NSColor { xyzResolved(\.disabledTint) }
    static var xyzFindMatch: NSColor { xyzResolved(\.findMatch) }
    static var xyzFindCurrent: NSColor { xyzResolved(\.findCurrent) }
    static var xyzFindToggleFill: NSColor { xyzResolved(\.findToggleFill) }
    static var xyzFindToggleInk: NSColor { xyzResolved(\.findToggleInk) }

    /// One syntax color per drawing appearance; falls back to quiet text when a kind is
    /// somehow undefined.
    static func xyzSyntax(_ kind: SyntaxTokenKind) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let theme = XYZTheme.resolved(dark: dark)
            return NSColor(xyz: theme.syntax.color(for: kind) ?? theme.secondaryText)
        }
    }

    /// The shared display metrics, so radii and alphas cannot drift per control.
    enum xyzDisplay {
        static let controlCornerRadius: CGFloat = 5
        static let panelCornerRadius: CGFloat = 12
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
