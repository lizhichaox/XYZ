import Foundation

public enum WorkspaceFileKind: Equatable, Sendable {
    /// Editor and Markdown preview.
    case markdown
    /// Editor only. Covers source, JSON, and dotfiles that are text.
    case plainText
    /// Not shown in the editor.
    case binary
    /// Over the in-memory edit limit.
    case tooLarge
}

public enum WorkspaceFileClassifier {
    public static let sampleLimit = 8_192
    /// Files larger than this stay out of the text view.
    public static let editLimit = 5_000_000

    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    public static func kind(name: String, byteCount: Int, sample: Data) -> WorkspaceFileKind {
        if byteCount > editLimit {
            return .tooLarge
        }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if sample.contains(0) {
            return .binary
        }
        if !sample.isEmpty && String(data: sample, encoding: .utf8) == nil {
            return .binary
        }
        if markdownExtensions.contains(ext) {
            return .markdown
        }
        return .plainText
    }
}

public enum WorkspaceDiskChange: Equatable, Sendable {
    case ignore
    case reload
    case conflict
}

public enum WorkspaceWriteDecision: Equatable, Sendable {
    case write
    case upToDate
    case conflict
}

/// Decides how an editor buffer and the bytes on disk can meet without a silent overwrite.
public enum WorkspaceFilePolicy {
    /// `disk` was read because the file changed under us. Local edits that are not saved win a conflict.
    public static func interpretChange(editor: String, lastSaved: String, disk: String) -> WorkspaceDiskChange {
        if disk == editor || disk == lastSaved {
            return .ignore
        }
        if editor == lastSaved {
            return .reload
        }
        return .conflict
    }

    /// `disk` is nil when the file is gone. A deleted file is recreated only when the user asks to overwrite.
    public static func decideWrite(editor: String, lastSaved: String, disk: String?, force: Bool) -> WorkspaceWriteDecision {
        guard let disk else {
            if force {
                return .write
            }
            return editor == lastSaved ? .upToDate : .conflict
        }
        if editor == disk {
            return .upToDate
        }
        if force || disk == lastSaved {
            return .write
        }
        return .conflict
    }
}
