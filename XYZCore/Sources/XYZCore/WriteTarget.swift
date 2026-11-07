import Foundation

/// Where a save should put the bytes of a file it opened through a symbolic link.
///
/// `Data.write(.atomic)` writes a new file and renames it over the path. That is safe
/// for the file's contents, but when the path is a symbolic link the rename replaces
/// the link itself: the link becomes a regular file and the file it pointed at keeps
/// its old text. Resolving the link first keeps the link a link and updates the file
/// the link names.
///
/// A hard link is not followed. Writing through one would mean editing in place and
/// giving up the atomic write; the same inode split is what every atomic save does.
public enum WorkspaceWriteTarget {
    /// The path to write. A symbolic link is followed, including a chain of links.
    /// A chain that loops falls back to `url` so the write still happens where the
    /// caller asked.
    public static func resolveForWriting(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        var visited: Set<String> = []
        for _ in 0..<32 {
            guard visited.insert(current.path).inserted else { return url }
            guard isSymbolicLink(current),
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)
            else {
                return current
            }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination).standardizedFileURL
                : current.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL
        }
        return url
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeSymbolicLink
    }
}
