import Foundation

/// How a Markdown document is shown.
///
/// Coding is the source. Preview keeps the source beside the rendered note.
/// Reading hides the source. The View menu and shortcuts switch these; the
/// reading surface itself has no mode buttons.
public enum EditorViewMode: String, CaseIterable, Codable, Sendable, Identifiable, Equatable {
    case coding
    case preview
    case reading

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .coding: return "Coding"
        case .preview: return "Preview"
        case .reading: return "Reading"
        }
    }

    /// Obsidian's Toggle Reading View. Reading returns to the editing mode you left.
    public static func toggleReading(
        current: EditorViewMode,
        editing: EditorViewMode
    ) -> (mode: EditorViewMode, editing: EditorViewMode) {
        if current == .reading {
            let back = editing == .reading ? EditorViewMode.preview : editing
            return (back, back)
        }
        return (.reading, current)
    }

    /// Typora's Source Code Mode. Coding toggles with Preview. Reading enters Coding.
    public static func toggleSource(current: EditorViewMode) -> EditorViewMode {
        current == .coding ? .preview : .coding
    }
}
