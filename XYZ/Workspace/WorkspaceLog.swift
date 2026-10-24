#if os(macOS)
import Foundation
import os

/// Unified log for folder opens. Paths are private; counts and states are public.
enum WorkspaceLog {
    static let logger = Logger(subsystem: "com.lizhichao.XYZ", category: "workspace")

    static func panelShown(
        kind: String,
        via: String,
        canChooseDirectories: Bool,
        canChooseFiles: Bool,
        showsHiddenFiles: Bool,
        allowsFolderType: Bool,
        prompt: String
    ) {
        let directories = flag(canChooseDirectories)
        let files = flag(canChooseFiles)
        let hidden = flag(showsHiddenFiles)
        let folderType = flag(allowsFolderType)
        logger.notice("panel shown kind=\(kind, privacy: .public) via=\(via, privacy: .public) canChooseDirectories=\(directories, privacy: .public) canChooseFiles=\(files, privacy: .public) showsHiddenFiles=\(hidden, privacy: .public) allowsFolderType=\(folderType, privacy: .public) prompt=\(prompt, privacy: .public)")
    }

    static func panelCancelled(kind: String) {
        logger.notice("panel cancelled kind=\(kind, privacy: .public)")
    }

    static func folderPicked(source: String, path: String) {
        logger.notice("folder picked source=\(source, privacy: .public) path=\(path, privacy: .private)")
    }

    static func workspaceWindow(path: String, state: String, openWindows: Int) {
        logger.notice("workspace window state=\(state, privacy: .public) openWindows=\(openWindows, privacy: .public) path=\(path, privacy: .private)")
    }

    static func rootEnumerated(path: String, count: Int) {
        logger.notice("root enumerated count=\(count, privacy: .public) path=\(path, privacy: .private)")
    }

    static func rootEnumerationFailed(path: String) {
        logger.error("root enumeration failed path=\(path, privacy: .private)")
    }

    static func bookmarkSaved(path: String, bytes: Int) {
        logger.notice("bookmark saved bytes=\(bytes, privacy: .public) path=\(path, privacy: .private)")
    }

    static func bookmarkRestored(path: String, stale: Bool) {
        let staleFlag = flag(stale)
        logger.notice("bookmark restored stale=\(staleFlag, privacy: .public) path=\(path, privacy: .private)")
    }

    static func bookmarkFailed(action: String, path: String, error: Error) {
        let code = (error as NSError).code
        let detail = (error as NSError).localizedDescription
        logger.error("bookmark failed action=\(action, privacy: .public) code=\(code, privacy: .public) path=\(path, privacy: .private) detail=\(detail, privacy: .private)")
    }

    static func bookmarksStored(kind: String, count: Int) {
        logger.notice("bookmarks stored kind=\(kind, privacy: .public) count=\(count, privacy: .public)")
    }

    static func restoreStarted(count: Int) {
        logger.notice("restore started count=\(count, privacy: .public)")
    }

    static func externalOpen(source: String, urlCount: Int, folderCount: Int) {
        logger.notice("external open source=\(source, privacy: .public) urlCount=\(urlCount, privacy: .public) folderCount=\(folderCount, privacy: .public)")
    }

    static func externalOpenFolder(source: String, path: String) {
        logger.notice("external open folder source=\(source, privacy: .public) path=\(path, privacy: .private)")
    }

    static func rejected(path: String, reason: String) {
        logger.error("folder rejected reason=\(reason, privacy: .public) path=\(path, privacy: .private)")
    }

    static func launchArgument(path: String) {
        logger.notice("launch argument XYZOpenFolder path=\(path, privacy: .private)")
    }

    static func openFailed(path: String, error: Error) {
        let code = (error as NSError).code
        let detail = (error as NSError).localizedDescription
        logger.error("open failed code=\(code, privacy: .public) path=\(path, privacy: .private) detail=\(detail, privacy: .private)")
    }

    private static func flag(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}
#endif
