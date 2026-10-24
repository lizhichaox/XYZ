#if os(macOS)
import AppKit
import Combine
import CryptoKit
import Foundation
import XYZCore

/// One open folder: a lazy tree plus the file currently in the editor.
@MainActor
final class WorkspaceSession: ObservableObject {
    let rootURL: URL
    let bookmark: Data?
    let displayName: String

    @Published var showsHiddenFiles = true
    @Published private(set) var children: [String: [WorkspaceNode]] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var loadErrors: [String: String] = [:]
    @Published var selectedPath: String?
    @Published private(set) var buffer: WorkspaceFileBuffer?
    @Published var rootError: String?
    @Published var actionMessage: String?
    @Published var nameQuery = "" {
        didSet {
            guard nameQuery != oldValue else { return }
            scheduleContentSearch()
        }
    }
    @Published private(set) var indexedEntries: [WorkspacePathEntry] = []
    @Published private(set) var contentHits: [WorkspaceContentHit] = []
    @Published private(set) var contentSearching = false
    @Published var viewMode: EditorViewMode
    /// Set when a new item should start inline rename once the row exists.
    var pendingEditPath: String?
    var focusSearchHandler: (() -> Void)?
    /// One preview for the life of this window. File switches push new text.
    let previewBridge = PreviewBridge(text: "")
    let previewHost = PreviewWebHost()
    let scrollLink = EditorScrollLink()
    private(set) var recentPaths: [String] = []

    private let monitor = DirectoryMonitor()
    private var accessStarted = false
    private var didStart = false
    private var fileWatchKey: String?
    private var reloadTasks: [String: Task<Void, Never>] = [:]
    private var loadGeneration: [String: Int] = [:]
    private var indexTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    private var indexGeneration = 0

    init(rootURL: URL, bookmark: Data?) {
        self.rootURL = rootURL
        self.bookmark = bookmark
        self.displayName = rootURL.lastPathComponent
        let saved = UserDefaults.standard.string(forKey: Self.viewModeKey(for: rootURL))
        self.viewMode = EditorViewMode.restored(saved)
        self.recentPaths = UserDefaults.standard.stringArray(forKey: Self.recentsKey(for: rootURL)) ?? []
    }

    func activate() {
        guard !didStart else { return }
        didStart = true
        accessStarted = rootURL.startAccessingSecurityScopedResource()
        previewHost.openFile = { [weak self] url in
            MainActor.assumeIsolated {
                self?.openLinked(url)
            }
        }
        if let saved = UserDefaults.standard.stringArray(forKey: Self.expansionKey(for: rootURL)) {
            expanded = Set(saved.filter { !$0.isEmpty && !WorkspaceContentSearch.shouldSkipRelativePath($0) })
        }
        load(parent: "")
        for path in expanded.sorted(by: { $0.count < $1.count }) {
            load(parent: path)
            watchDirectory(path)
        }
        monitor.watch(url: rootURL, key: "") { [weak self] in
            Task { @MainActor in
                self?.scheduleReload("")
            }
        }
        scheduleIndex()
    }

    func shutdown() {
        buffer?.flush()
        monitor.stop()
        reloadTasks.values.forEach { $0.cancel() }
        indexTask?.cancel()
        contentTask?.cancel()
        if accessStarted {
            rootURL.stopAccessingSecurityScopedResource()
            accessStarted = false
        }
    }

    func visibleChildren(of parent: String) -> [WorkspaceNode] {
        WorkspaceTreeFilter.visible(children[parent] ?? [], showsHidden: showsHiddenFiles)
    }

    func isExpanded(_ path: String) -> Bool {
        expanded.contains(path)
    }

    /// Expand every folder above a file so the outline can select and scroll to it.
    func revealAncestors(of relativePath: String) {
        let chain = WorkspacePaths.ancestors(of: relativePath)
        guard !chain.isEmpty else { return }
        var next = expanded
        for ancestor in chain {
            next.insert(ancestor)
            if children[ancestor] == nil {
                load(parent: ancestor)
            }
            watchDirectory(ancestor)
        }
        guard next != expanded else { return }
        expanded = next
        rememberExpansion()
    }

    func setExpanded(_ node: WorkspaceNode, _ isExpanded: Bool) {
        guard node.isDirectory else { return }
        if isExpanded {
            expanded.insert(node.relativePath)
            if children[node.relativePath] == nil {
                load(parent: node.relativePath)
            }
            watchDirectory(node.relativePath)
        } else {
            collapse(node.relativePath)
        }
        rememberExpansion()
    }

    var searchTree: WorkspaceSearchTree? {
        let trimmed = nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let source = indexedEntries.isEmpty ? flattenedLoadedEntries() : indexedEntries
        return WorkspaceTreeQuery.filter(entries: source, query: trimmed)
    }

    func selectViewMode(_ mode: EditorViewMode, source: String) {
        let previous = viewMode
        if previous != mode {
            scrollLink.noteToggle(to: mode)
        }
        viewMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.viewModeKey(for: rootURL))
        if previous != viewMode {
            ViewModeLog.changed(from: previous.rawValue, to: viewMode.rawValue, source: source)
        }
    }

    func toggleViewMode(source: String) {
        guard buffer == nil || buffer?.kind == .markdown else { return }
        selectViewMode(viewMode.toggled(), source: source)
    }

    func focusSearch() {
        focusSearchHandler?()
    }

    /// A link in Reading. Files in this folder open here; anything else goes to its default app.
    func openLinked(_ url: URL) {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else {
            NSWorkspace.shared.open(url)
            return
        }
        openRelative(String(path.dropFirst(root.count + 1)))
    }

    func openRelative(_ relativePath: String) {
        if let node = node(at: relativePath) {
            openFile(node)
            return
        }
        let name = (relativePath as NSString).lastPathComponent
        openFile(WorkspaceNode(
            name: name,
            relativePath: relativePath,
            isDirectory: false,
            isHidden: WorkspacePaths.isHidden(name: name, resourceHidden: false)
        ))
    }

    func createItem(directory: Bool, in parent: String) {
        let names = Set((children[parent] ?? []).map(\.name))
        let preferred = directory ? "Untitled Folder" : "Untitled.md"
        let name = WorkspaceItemName.unique(preferred: preferred, existing: names)
        let relative = WorkspacePaths.child(parent: parent, name: name)
        let destination = url(for: relative)
        if !parent.isEmpty {
            expanded.insert(parent)
            rememberExpansion()
            if children[parent] == nil {
                load(parent: parent)
                watchDirectory(parent)
            }
        }
        Task { [weak self] in
            do {
                if directory {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                } else {
                    try Data().write(to: destination, options: .atomic)
                }
            } catch {
                await MainActor.run { self?.actionFailed("Couldn't create this item.") }
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.pendingEditPath = relative
                if !directory {
                    self.openFile(WorkspaceNode(
                        name: name,
                        relativePath: relative,
                        isDirectory: false,
                        isHidden: name.hasPrefix(".")
                    ))
                }
                self.scheduleReload(parent)
                self.scheduleIndex()
            }
        }
    }

    /// Nil when the rename landed. A string is a message safe to show in an alert.
    func rename(relativePath: String, to rawName: String) -> String? {
        if let issue = WorkspaceItemName.issue(with: rawName) { return issue }
        let name = WorkspaceItemName.normalized(rawName)
        let current = (relativePath as NSString).lastPathComponent
        if name == current { return nil }
        let parent = WorkspacePaths.parent(of: relativePath)
        if (children[parent] ?? []).contains(where: { $0.name == name }) {
            return "An item with that name already exists."
        }
        let destination = WorkspacePaths.child(parent: parent, name: name)
        do {
            try FileManager.default.moveItem(at: url(for: relativePath), to: url(for: destination))
        } catch {
            return "Couldn't rename this item."
        }
        retarget(from: relativePath, to: destination)
        if buffer?.relativePath == relativePath {
            buffer?.flush()
            openFile(WorkspaceNode(
                name: name,
                relativePath: destination,
                isDirectory: false,
                isHidden: name.hasPrefix(".")
            ))
        } else if let selected = selectedPath, selected == relativePath || selected.hasPrefix(relativePath + "/") {
            selectedPath = destination + selected.dropFirst(relativePath.count)
        }
        scheduleReload(parent)
        scheduleIndex()
        return nil
    }

    func trash(relativePath: String) throws {
        if let open = buffer?.relativePath, open == relativePath || open.hasPrefix(relativePath + "/") {
            buffer?.flush()
            buffer = nil
            selectedPath = nil
        }
        try FileManager.default.trashItem(at: url(for: relativePath), resultingItemURL: nil)
        expanded = Set(expanded.filter { $0 != relativePath && !$0.hasPrefix(relativePath + "/") })
        rememberExpansion()
        scheduleReload(WorkspacePaths.parent(of: relativePath))
        scheduleIndex()
    }

    func move(relativePath: String, toParent parent: String) -> String? {
        guard WorkspaceItemName.canMove(item: relativePath, into: parent) else { return nil }
        let current = (relativePath as NSString).lastPathComponent
        let unique = WorkspaceItemName.unique(preferred: current, existing: Set((children[parent] ?? []).map(\.name)))
        let destination = WorkspacePaths.child(parent: parent, name: unique)
        do {
            if !parent.isEmpty {
                try FileManager.default.createDirectory(at: url(for: parent), withIntermediateDirectories: true)
            }
            try FileManager.default.moveItem(at: url(for: relativePath), to: url(for: destination))
        } catch {
            return "Couldn't move this item."
        }
        retarget(from: relativePath, to: destination)
        if buffer?.relativePath == relativePath {
            buffer?.flush()
            openFile(WorkspaceNode(
                name: unique,
                relativePath: destination,
                isDirectory: false,
                isHidden: unique.hasPrefix(".")
            ))
        }
        scheduleReload(WorkspacePaths.parent(of: relativePath))
        scheduleReload(parent)
        scheduleIndex()
        return nil
    }

    func clearQuery() {
        nameQuery = ""
    }

    func openFile(_ node: WorkspaceNode) {
        guard !node.isDirectory else { return }
        revealAncestors(of: node.relativePath)
        guard buffer?.relativePath != node.relativePath else {
            selectedPath = node.relativePath
            return
        }
        selectedPath = node.relativePath
        buffer?.flush()
        let path = node.relativePath
        let url = url(for: path)
        Task { [weak self] in
            let loaded = await Self.readForEditing(url: url, name: node.name)
            await MainActor.run {
                guard let self, self.selectedPath == path else { return }
                self.install(loaded, relativePath: path, url: url)
                self.noteRecent(path)
            }
        }
    }

    func newItem(directory: Bool) {
        let parent: String
        if let path = buffer?.relativePath {
            parent = WorkspacePaths.parent(of: path)
        } else if let path = selectedPath, node(at: path)?.isDirectory == true {
            parent = path
        } else {
            parent = ""
        }
        createItem(directory: directory, in: parent)
    }

    func reloadOpenFile() {
        buffer?.noteExternalChange()
    }

    func revealOpenItem() {
        NSWorkspace.shared.activateFileViewerSelecting([buffer?.url ?? rootURL])
    }

    func copyOpenPath() {
        let path = buffer?.url.path ?? rootURL.path
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    func openInDocumentWindow(relativePath: String) {
        let url = url(for: relativePath)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            guard let error else { return }
            WorkspaceLog.openFailed(path: url.path, error: error)
        }
    }

    func paletteFiles() -> [PaletteFile] {
        let source = indexedEntries.isEmpty ? flattenedLoadedEntries() : indexedEntries
        let rank = Dictionary(uniqueKeysWithValues: recentPaths.enumerated().map { index, path in
            (path, recentPaths.count - index)
        })
        return source.filter { !$0.isDirectory }.map { entry in
            PaletteFile(
                name: entry.name,
                relativePath: entry.relativePath,
                recency: rank[entry.relativePath] ?? 0
            )
        }
    }

    func noteRecent(_ path: String) {
        recentPaths.removeAll { $0 == path }
        recentPaths.insert(path, at: 0)
        if recentPaths.count > 40 {
            recentPaths.removeLast(recentPaths.count - 40)
        }
        UserDefaults.standard.set(recentPaths, forKey: Self.recentsKey(for: rootURL))
    }

    func url(for relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(rootURL) { partial, part in
            partial.appendingPathComponent(String(part))
        }
    }

    func node(at relativePath: String) -> WorkspaceNode? {
        let parent = WorkspacePaths.parent(of: relativePath)
        return children[parent]?.first { $0.relativePath == relativePath }
    }

    private func actionFailed(_ message: String) {
        actionMessage = message
    }

    private func watchDirectory(_ path: String) {
        monitor.watch(url: url(for: path), key: path) { [weak self] in
            Task { @MainActor in
                self?.scheduleReload(path)
            }
        }
    }

    private func rememberExpansion() {
        let kept = expanded
            .filter { !$0.isEmpty && !WorkspaceContentSearch.shouldSkipRelativePath($0) }
            .sorted()
        UserDefaults.standard.set(kept, forKey: Self.expansionKey(for: rootURL))
    }

    private func retarget(from old: String, to new: String) {
        expanded = Set(expanded.map { path in
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
            return path
        })
        rememberExpansion()
    }

    private func flattenedLoadedEntries() -> [WorkspacePathEntry] {
        var entries: [WorkspacePathEntry] = []
        func walk(_ parent: String) {
            for node in children[parent] ?? [] {
                entries.append(WorkspacePathEntry(
                    name: node.name,
                    relativePath: node.relativePath,
                    isDirectory: node.isDirectory,
                    isHidden: node.isHidden
                ))
                if node.isDirectory {
                    walk(node.relativePath)
                }
            }
        }
        walk("")
        return entries
    }

    private func scheduleIndex() {
        indexTask?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        let root = rootURL
        indexTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let entries = await Task.detached(priority: .utility) {
                WorkspaceIndexScan.entries(at: root)
            }.value
            guard let self, self.indexGeneration == generation else { return }
            self.indexedEntries = entries
            if !self.nameQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.scheduleContentSearch()
            }
        }
    }

    private func scheduleContentSearch() {
        contentTask?.cancel()
        let query = nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            contentHits = []
            contentSearching = false
            return
        }
        contentSearching = true
        let files = indexedEntries.filter {
            !$0.isDirectory && !WorkspaceContentSearch.shouldSkipRelativePath($0.relativePath)
        }
        let root = rootURL
        contentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let hits = await Self.searchContents(files: files, root: root, query: query)
            guard !Task.isCancelled, let self else { return }
            guard self.nameQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.contentHits = hits
            self.contentSearching = false
        }
    }

    private static func searchContents(
        files: [WorkspacePathEntry],
        root: URL,
        query: String
    ) async -> [WorkspaceContentHit] {
        await Task.detached(priority: .utility) {
            var found: [WorkspaceContentHit] = []
            for entry in files {
                if Task.isCancelled || found.count >= WorkspaceContentSearch.hitLimit { break }
                let url = entry.relativePath.split(separator: "/").reduce(root) {
                    $0.appendingPathComponent(String($1))
                }
                let size = WorkspaceFileCoordination.fileSize(at: url)
                let sample = (try? WorkspaceFileCoordination.readSample(
                    at: url,
                    limit: WorkspaceFileClassifier.sampleLimit
                )) ?? Data()
                if WorkspaceContentSearch.shouldSkipContents(name: entry.name, byteCount: size, sample: sample) {
                    continue
                }
                guard let data = try? WorkspaceFileCoordination.readData(at: url),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let room = min(3, WorkspaceContentSearch.hitLimit - found.count)
                found.append(contentsOf: WorkspaceContentSearch.hits(
                    in: text,
                    relativePath: entry.relativePath,
                    query: query,
                    limit: room
                ))
            }
            return found
        }.value
    }

    private static func token(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func expansionKey(for url: URL) -> String {
        "xyz.workspace.expansion." + token(for: url)
    }

    private static func viewModeKey(for url: URL) -> String {
        "xyz.workspace.viewMode." + token(for: url)
    }

    private static func recentsKey(for url: URL) -> String {
        "xyz.workspace.recents." + token(for: url)
    }

    private func collapse(_ path: String) {
        let descendants = expanded.filter { $0 == path || $0.hasPrefix(path + "/") }
        for item in descendants {
            expanded.remove(item)
            monitor.unwatch(key: item)
            reloadTasks[item]?.cancel()
        }
    }

    private func scheduleReload(_ parent: String) {
        reloadTasks[parent]?.cancel()
        reloadTasks[parent] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.load(parent: parent)
        }
    }

    private func load(parent: String) {
        loadGeneration[parent, default: 0] += 1
        let generation = loadGeneration[parent] ?? 0
        let url = url(for: parent)
        Task { [weak self] in
            let result = await Task.detached { () -> Result<[WorkspaceNode], Error> in
                do {
                    return .success(try WorkspaceDirectoryLoader.children(parentRelativePath: parent, directoryURL: url))
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                guard let self, self.loadGeneration[parent] == generation else { return }
                switch result {
                case .success(let nodes):
                    self.children[parent] = nodes
                    self.loadErrors[parent] = nil
                    if parent.isEmpty {
                        self.rootError = nil
                        WorkspaceLog.rootEnumerated(path: self.rootURL.path, count: nodes.count)
                    }
                    self.noteOpenFileStillPresent(parent: parent, nodes: nodes)
                    self.scheduleIndex()
                case .failure:
                    let message = "Couldn't read this folder."
                    self.loadErrors[parent] = message
                    if parent.isEmpty {
                        self.rootError = message
                        WorkspaceLog.rootEnumerationFailed(path: self.rootURL.path)
                    }
                }
            }
        }
    }

    private func noteOpenFileStillPresent(parent: String, nodes: [WorkspaceNode]) {
        guard let path = buffer?.relativePath, WorkspacePaths.parent(of: path) == parent else { return }
        if !nodes.contains(where: { $0.relativePath == path }) {
            buffer?.noteMissing()
        }
    }

    private func install(_ loaded: LoadedFile, relativePath: String, url: URL) {
        let buffer = WorkspaceFileBuffer(
            url: url,
            relativePath: relativePath,
            kind: loaded.kind,
            text: loaded.text
        )
        self.buffer = buffer
        previewBridge.send(loaded.text)
        if let fileWatchKey {
            monitor.unwatch(key: fileWatchKey)
        }
        guard loaded.kind == .markdown || loaded.kind == .plainText else { return }
        let key = "file:" + relativePath
        fileWatchKey = key
        monitor.watch(url: url, key: key) { [weak buffer] in
            Task { @MainActor in
                buffer?.noteExternalChange()
            }
        }
    }

    private struct LoadedFile: Sendable {
        var kind: WorkspaceFileKind
        var text: String
    }

    private static func readForEditing(url: URL, name: String) async -> LoadedFile {
        await Task.detached {
            let size = WorkspaceFileCoordination.fileSize(at: url)
            var sample = (try? WorkspaceFileCoordination.readSample(at: url, limit: WorkspaceFileClassifier.sampleLimit)) ?? Data()
            var fullFile: Data?
            if WorkspaceFileClassifier.needsFullRead(byteCount: size, sample: sample),
               let full = try? WorkspaceFileCoordination.readData(at: url) {
                fullFile = full
                sample = full
            }
            var kind = WorkspaceFileClassifier.kind(
                name: name,
                byteCount: size,
                sample: sample,
                fullFile: fullFile
            )
            guard kind == .markdown || kind == .plainText else {
                return LoadedFile(kind: kind, text: "")
            }
            let data = (fullFile?.count == size ? fullFile : nil) ?? (try? WorkspaceFileCoordination.readData(at: url))
            guard let data, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                kind = .binary
                return LoadedFile(kind: kind, text: "")
            }
            return LoadedFile(kind: kind, text: text)
        }.value
    }
}

/// Text for one workspace file. Keystrokes stay here and are written with a coordinated save.
@MainActor
final class WorkspaceFileBuffer: ObservableObject {
    let url: URL
    let relativePath: String
    @Published private(set) var kind: WorkspaceFileKind
    @Published private(set) var reloadToken = 0
    @Published private(set) var conflictText: String?
    @Published private(set) var isMissing = false
    @Published private(set) var status: String?
    private(set) var text: String
    private var lastSaved: String
    private var saveTask: Task<Void, Never>?

    fileprivate init(url: URL, relativePath: String, kind: WorkspaceFileKind, text: String) {
        self.url = url
        self.relativePath = relativePath
        self.kind = kind
        self.text = text
        self.lastSaved = text
        Self.nextGeneration += 1
        generation = Self.nextGeneration
    }

    /// Changes when the file is opened or reloaded, so one text view can swap documents.
    var editorToken: Int { generation &+ reloadToken }

    private static var nextGeneration = 0
    private let generation: Int

    func userEdited(_ newText: String) {
        text = newText
        if conflictText != nil || isMissing {
            saveTask?.cancel()
            return
        }
        if newText == lastSaved {
            saveTask?.cancel()
            return
        }
        scheduleSave()
    }

    /// Writes immediately. Used when switching files and when the window closes.
    func flush() {
        saveTask?.cancel()
        save(force: false)
    }

    func reloadFromDisk() {
        guard let conflictText else { return }
        apply(text: conflictText)
    }

    func overwrite() {
        saveTask?.cancel()
        save(force: true)
    }

    func noteExternalChange() {
        let url = url
        Task { [weak self] in
            let data = try? await Task.detached {
                try WorkspaceFileCoordination.readData(at: url)
            }.value
            await MainActor.run {
                guard let self else { return }
                guard let data else {
                    self.noteMissing()
                    return
                }
                guard !data.contains(0), let disk = String(data: data, encoding: .utf8) else {
                    self.kind = .binary
                    self.conflictText = nil
                    return
                }
                self.isMissing = false
                switch WorkspaceFilePolicy.interpretChange(editor: self.text, lastSaved: self.lastSaved, disk: disk) {
                case .ignore:
                    if self.text == disk {
                        self.lastSaved = disk
                    }
                case .reload:
                    self.apply(text: disk)
                case .conflict:
                    self.conflictText = disk
                }
            }
        }
    }

    func noteMissing() {
        isMissing = true
        if text != lastSaved {
            conflictText = nil
            status = "This file was removed. Overwrite to save your edits back."
        }
    }

    private func apply(text: String) {
        self.text = text
        lastSaved = text
        conflictText = nil
        isMissing = false
        status = nil
        reloadToken += 1
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save(force: false)
        }
    }

    private func save(force: Bool) {
        guard kind == .markdown || kind == .plainText else { return }
        guard force || text != lastSaved else { return }
        let editor = text
        let saved = lastSaved
        do {
            let (decision, disk) = try WorkspaceFileCoordination.updateText(
                at: url,
                editor: editor,
                lastSaved: saved,
                force: force
            )
            switch decision {
            case .write:
                lastSaved = editor
                conflictText = nil
                isMissing = false
                status = nil
            case .upToDate:
                if let disk, disk == text {
                    lastSaved = disk
                }
            case .conflict:
                conflictText = disk
                status = disk == nil ? "This file was removed." : "This file changed on disk."
            }
        } catch {
            status = "Couldn't save this file."
        }
    }
}

/// Name-only walk. Skips the inside of `.git`, `node_modules`, and `.build`, and stops at a cap.
private enum WorkspaceIndexScan {
    static let cap = 20_000

    static func entries(at root: URL) -> [WorkspacePathEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        let rootPath = root.standardizedFileURL.path
        var results: [WorkspacePathEntry] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let name = url.lastPathComponent
            if name.isEmpty || name == "." || name == ".." { continue }
            let values = try? url.resourceValues(forKeys: keys)
            let isLink = values?.isSymbolicLink == true
            let isDirectory = values?.isDirectory == true && !isLink
            if isDirectory && WorkspaceContentSearch.shouldSkipDirectory(name) {
                enumerator.skipDescendants()
            }
            let full = url.standardizedFileURL.path
            let prefix = rootPath + "/"
            guard full.hasPrefix(prefix) else { continue }
            let relative = String(full.dropFirst(prefix.count))
            results.append(WorkspacePathEntry(
                name: name,
                relativePath: relative,
                isDirectory: isDirectory,
                isHidden: WorkspacePaths.isHidden(name: name, resourceHidden: values?.isHidden == true)
            ))
            if results.count >= cap { break }
        }
        return results
    }
}
#endif
