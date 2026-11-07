import Foundation

/// Whether a file is the folder a note owns, or a folder below it.
///
/// Reading lets a note show pictures next to it. The page asks for a path in the
/// custom `xyz-asset` scheme, so the app has to decide whether that path belongs to
/// the note at all. `standardizedFileURL` removes `..`, and `resolvingSymlinksInPath`
/// makes a link that points outside the folder count as outside.
public enum WorkspacePathScope {
    public static func contains(root: URL, file: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        if filePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix)
    }
}
