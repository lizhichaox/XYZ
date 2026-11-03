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
    static let readableWidthKey = "xyz.text.readableWidth"
    /// Line numbers beside Source. On unless turned off.
    static let lineNumbersKey = "xyz.editor.lineNumbers"
    /// Line numbers while reading. Off unless turned on. Editing always shows them.
    static let readingLineNumbersKey = "xyz.editor.readingLineNumbers"
    /// Break long lines to the editor width. On unless turned off.
    static let wordWrapKey = "xyz.editor.wordWrap"
    static let defaultFontSize: Double = 16
    static let fontSizes: ClosedRange<Double> = 12...24
    static let markdown = XYZEditorStyle()

    static func clampedFontSize(_ size: Double) -> Double {
        min(fontSizes.upperBound, max(fontSizes.lowerBound, size.rounded()))
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

    func noteToggle(to destination: EditorViewMode) {
        pending = (capture(), destination)
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
                monospaced: monospaced || forcesMonospace,
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
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// Sidebar and status bar. A step off the editor's text background, in both appearances.
    static var sidebarBackground: Color {
        #if os(macOS)
        Color(nsColor: .xyzSidebar)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

#if os(macOS)
extension NSColor {
    /// Flat sidebar. Light is a step off white (`#F8F8F8`). Dark is `#181818`, a step under the editor.
    static var xyzSidebar: NSColor {
        NSColor(name: "xyz.sidebar") { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if dark {
                return NSColor(srgbRed: 24.0 / 255.0, green: 24.0 / 255.0, blue: 24.0 / 255.0, alpha: 1)
            }
            return NSColor(srgbRed: 248.0 / 255.0, green: 248.0 / 255.0, blue: 248.0 / 255.0, alpha: 1)
        }
    }
}
#endif
