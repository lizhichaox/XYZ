import SwiftUI
import XYZCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Visual defaults for the Markdown editor.
///
/// The default face is the system font (SF Pro, with PingFang SC for Chinese).
/// A monospaced face is available from Settings and stored in `monospacedKey`.
struct XYZEditorStyle: Equatable {
    var fontSize: CGFloat = 16
    /// Line box height relative to the font size. Markdown source stores a hard return
    /// on every line, so this is a minimum line height rather than spacing between wraps.
    var lineHeight: CGFloat = 1.7
    var horizontalInset: CGFloat = 24
    var verticalInset: CGFloat = 32
    var monospaced: Bool = false

    /// Side padding is 5% of the pane, clamped to 24...64 points. The text uses the remaining width.
    static func sideInset(for paneWidth: CGFloat) -> CGFloat {
        min(64, max(24, floor(paneWidth * 0.05)))
    }

    static let monospacedKey = "xyz.editor.monospaced"
    static let markdown = XYZEditorStyle()

    func paragraphStyle(naturalLineHeight: CGFloat) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let target = max(naturalLineHeight, (fontSize * lineHeight).rounded(.up))
        paragraph.minimumLineHeight = target
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping
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
    private var pending: (anchor: EditorScrollAnchor, destination: EditorViewMode)?

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
    /// Markdown list continuation and ⌘B / ⌘I. Plain text leaves those keys alone.
    var markup: Bool = true
    var onTextChange: (String) -> Void

    @AppStorage(XYZEditorStyle.monospacedKey) private var monospaced = false

    var body: some View {
        #if os(macOS)
        XYZMacEditor(
            text: text,
            isEditable: isEditable,
            undoManager: undoManager,
            reloadToken: reloadToken,
            monospaced: monospaced,
            scrollLink: scrollLink,
            markup: markup,
            onTextChange: onTextChange
        )
        #else
        XYZIOSEditor(
            text: text,
            isEditable: isEditable,
            undoManager: undoManager,
            reloadToken: reloadToken,
            monospaced: monospaced,
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
}
