#if os(macOS)
import Combine
import Darwin
import Foundation
import XYZCore

/// Watches one file or directory at a time, per key. Events are debounced onto the main queue.
final class DirectoryMonitor {
    private final class Watch {
        let source: DispatchSourceFileSystemObject
        var debounce: DispatchWorkItem?
        init(source: DispatchSourceFileSystemObject) {
            self.source = source
        }
    }

    private let queue = DispatchQueue(label: "xyz.workspace.fs", qos: .utility)
    private var watches: [String: Watch] = [:]
    private var stopped = false

    func watch(url: URL, key: String, onChange: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.replaceWatch(url: url, key: key, onChange: onChange)
        }
    }

    func unwatch(key: String) {
        queue.async { [weak self] in
            self?.cancel(key)
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            for key in Array(watches.keys) {
                cancel(key)
            }
        }
    }

    private func replaceWatch(url: URL, key: String, onChange: @escaping () -> Void) {
        cancel(key)
        let fd = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return open(pointer, O_EVTONLY)
        }
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )
        let watch = Watch(source: source)
        source.setEventHandler { [weak watch] in
            guard let watch else { return }
            watch.debounce?.cancel()
            let item = DispatchWorkItem(block: onChange)
            watch.debounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
        }
        source.setCancelHandler {
            close(fd)
        }
        watches[key] = watch
        source.resume()
    }

    private func cancel(_ key: String) {
        guard let watch = watches.removeValue(forKey: key) else { return }
        watch.debounce?.cancel()
        watch.source.cancel()
    }
}

enum WorkspaceFileCoordination {
    static func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    static func readSample(at url: URL, limit: Int) throws -> Data {
        try coordinatedRead(at: url) { url in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: limit) ?? Data()
        }
    }

    static func readData(at url: URL) throws -> Data {
        try coordinatedRead(at: url) { url in
            try Data(contentsOf: url)
        }
    }

    /// Read the current bytes and maybe replace them, inside one coordinated write.
    static func updateText(
        at url: URL,
        editor: String,
        lastSaved: String,
        force: Bool
    ) throws -> (WorkspaceWriteDecision, String?) {
        var decision = WorkspaceWriteDecision.upToDate
        var diskText: String?
        var inner: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: .forMerging,
            error: &coordinationError
        ) { url in
            do {
                let exists = FileManager.default.fileExists(atPath: url.path)
                let disk: String?
                if exists {
                    let data = try Data(contentsOf: url)
                    guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
                        decision = .conflict
                        return
                    }
                    disk = text
                } else {
                    disk = nil
                }
                diskText = disk
                decision = WorkspaceFilePolicy.decideWrite(
                    editor: editor,
                    lastSaved: lastSaved,
                    disk: disk,
                    force: force
                )
                if decision == .write {
                    try Data(editor.utf8).write(to: url, options: .atomic)
                }
            } catch {
                inner = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let inner { throw inner }
        return (decision, diskText)
    }

    private static func coordinatedRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        var value: T?
        var inner: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            do {
                value = try body(url)
            } catch {
                inner = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let inner { throw inner }
        guard let value else {
            throw CocoaError(.fileReadUnknown)
        }
        return value
    }
}

struct WorkspaceBookmark: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var data: Data
}

enum WorkspaceBookmarks {
    static func make(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) throws -> URL {
        var stale = false
        return try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}

/// Recent folders and the set to restore next launch. Bookmarks stay in UserDefaults, not in git.
@MainActor
final class WorkspaceLibrary: ObservableObject {
    static let shared = WorkspaceLibrary()

    @Published private(set) var recents: [WorkspaceBookmark] = []
    @Published private(set) var openBookmarks: [WorkspaceBookmark] = []

    private let recentsKey = "xyz.workspace.recents"
    private let openKey = "xyz.workspace.open"
    private let limit = 10

    private init() {
        recents = Self.load(recentsKey)
        openBookmarks = Self.load(openKey)
    }

    func remember(name: String, data: Data, url: URL) {
        let bookmark = WorkspaceBookmark(id: UUID(), name: name, data: data)
        recents.removeAll { existing in
            if existing.data == data { return true }
            guard let resolved = try? WorkspaceBookmarks.resolve(existing.data) else { return false }
            return resolved.standardizedFileURL.path == url.standardizedFileURL.path
        }
        recents.insert(bookmark, at: 0)
        if recents.count > limit {
            recents.removeLast(recents.count - limit)
        }
        Self.store(recents, key: recentsKey)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: recentsKey)
    }

    func syncOpen(_ bookmarks: [WorkspaceBookmark]) {
        openBookmarks = bookmarks
        Self.store(bookmarks, key: openKey)
    }

    private static func load(_ key: String) -> [WorkspaceBookmark] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([WorkspaceBookmark].self, from: data)) ?? []
    }

    private static func store(_ bookmarks: [WorkspaceBookmark], key: String) {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
#endif
