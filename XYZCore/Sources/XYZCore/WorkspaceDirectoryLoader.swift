import Foundation

/// Lists one directory. Callers run this off the main thread.
///
/// The listing is not recursive, so a large child such as `node_modules` or `.git`
/// costs nothing until that folder is expanded. Hidden names are included.
/// Symbolic links are reported as files so a link cycle cannot be walked.
public enum WorkspaceDirectoryLoader {
    public static func children(parentRelativePath: String, directoryURL: URL) throws -> [WorkspaceNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var nodes: [WorkspaceNode] = []
        nodes.reserveCapacity(urls.count)
        for url in urls {
            let name = url.lastPathComponent
            if name.isEmpty || name == "." || name == ".." { continue }
            let values = try? url.resourceValues(forKeys: keys)
            let isLink = values?.isSymbolicLink == true
            let isDirectory = (values?.isDirectory == true) && !isLink
            let node = WorkspaceNode(
                name: name,
                relativePath: WorkspacePaths.child(parent: parentRelativePath, name: name),
                isDirectory: isDirectory,
                isHidden: WorkspacePaths.isHidden(name: name, resourceHidden: values?.isHidden == true)
            )
            nodes.append(node)
        }
        return WorkspaceTreeSort.ordered(nodes)
    }
}
