import Foundation

/// One entry in a workspace tree.
///
/// `relativePath` uses "/" separators and is relative to the folder the user opened.
/// An empty path is the workspace root, which is not itself a node.
public struct WorkspaceNode: Identifiable, Hashable, Sendable {
    public var name: String
    public var relativePath: String
    public var isDirectory: Bool
    public var isHidden: Bool

    public var id: String { relativePath }

    public init(name: String, relativePath: String, isDirectory: Bool, isHidden: Bool) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isHidden = isHidden
    }
}

public enum WorkspacePaths {
    public static func child(parent: String, name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    public static func parent(of relativePath: String) -> String {
        guard let index = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<index])
    }

    /// Folder paths from the workspace root down to the parent of `relativePath`.
    public static func ancestors(of relativePath: String) -> [String] {
        var chain: [String] = []
        var current = parent(of: relativePath)
        while !current.isEmpty {
            chain.append(current)
            current = parent(of: current)
        }
        return chain.reversed()
    }

    /// The folders a file sits in, from the workspace root down, for the window subtitle.
    /// A deep path keeps the root and the nearest folders with `…` between: `root › … › b › c`.
    public static func breadcrumb(rootName: String, relativePath: String, limit: Int = 5) -> [String] {
        let folders = ancestors(of: relativePath).map { path in
            path.split(separator: "/").last.map(String.init) ?? path
        }
        let chain = [rootName] + folders
        guard limit >= 3, chain.count > limit else { return chain }
        return [chain[0], "…"] + chain.suffix(limit - 2)
    }

    /// Dotfiles, and names the platform already marked hidden.
    public static func isHidden(name: String, resourceHidden: Bool) -> Bool {
        name.hasPrefix(".") || resourceHidden
    }
}

public enum WorkspaceTreeSort {
    /// Folders first, then Finder-style natural order (`localizedStandardCompare`), so v0.0.10 follows v0.0.9.
    public static func ordered(_ nodes: [WorkspaceNode]) -> [WorkspaceNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            let compared = lhs.name.localizedStandardCompare(rhs.name)
            if compared == .orderedSame {
                return lhs.name < rhs.name
            }
            return compared == .orderedAscending
        }
    }
}

public enum WorkspaceTreeFilter {
    public static func visible(_ nodes: [WorkspaceNode], showsHidden: Bool) -> [WorkspaceNode] {
        guard showsHidden else {
            return nodes.filter { !$0.isHidden }
        }
        return nodes
    }
}
