import Foundation

/// Reading resolves a relative link against the note's own folder. Obsidian-style wiki
/// links name a path from the workspace root, so a note in a subfolder would land one
/// folder too deep (`ST/MEM/ST/AGENTS.md`). When that note-relative file does not exist,
/// the same path under the workspace root is the document the link meant.
public enum LinkedNotePath {
    /// Returns the path relative to the workspace root, or nil when there is no such file.
    /// Paths are slash-separated and already standardized by the caller.
    public static func rootRelative(
        linkPath: String,
        noteFolderPath: String,
        rootPath: String,
        isFile: (String) -> Bool
    ) -> String? {
        let folder = noteFolderPath.hasSuffix("/") ? String(noteFolderPath.dropLast()) : noteFolderPath
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let prefix = folder + "/"
        guard linkPath.hasPrefix(prefix) else { return nil }
        let relative = String(linkPath.dropFirst(prefix.count))
        guard !relative.isEmpty else { return nil }
        return isFile(root + "/" + relative) ? relative : nil
    }
}
