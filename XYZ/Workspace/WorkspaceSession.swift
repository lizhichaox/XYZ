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
    @Published private(set) var tabStrip = EditorTabStrip()
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
    private var buffers: [String: WorkspaceFileBuffer] = [:]
    private var pendingRevealLine: Int?
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
        for open in buffers.values {
            open.flush()
        }
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
        guard let buffer, Self.canRead(buffer) else { return }
        selectViewMode(viewMode.toggled(), source: source)
    }

    private static func canRead(_ buffer: WorkspaceFileBuffer) -> Bool {
        guard buffer.kind == .markdown || buffer.kind == .plainText else { return false }
        return FileFormats.format(for: buffer.relativePath).reading != .none
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

    func openRelative(_ relativePath: String, pin: Bool = true, line: Int? = nil) {
        if let node = node(at: relativePath) {
            openFile(node, pin: pin, line: line)
            return
        }
        let name = (relativePath as NSString).lastPathComponent
        openFile(WorkspaceNode(
            name: name,
            relativePath: relativePath,
            isDirectory: false,
            isHidden: WorkspacePaths.isHidden(name: name, resourceHidden: false)
        ), pin: pin, line: line)
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
                await MainActor.run { self?.actionFailed(String(localized: "Couldn't create this item.")) }
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
                    ), pin: true)
                }
                self.scheduleReload(parent)
                self.scheduleIndex()
            }
        }
    }

    /// Nil when the rename landed. A string is a message safe to show in an alert.
    func rename(relativePath: String, to rawName: String) -> String? {
        if let issue = WorkspaceItemName.issue(with: rawName) { return String(localized: String.LocalizationValue(issue)) }
        let name = WorkspaceItemName.normalized(rawName)
        let current = (relativePath as NSString).lastPathComponent
        if name == current { return nil }
        let parent = WorkspacePaths.parent(of: relativePath)
        if (children[parent] ?? []).contains(where: { $0.name == name }) {
            return String(localized: "An item with that name already exists.")
        }
        let destination = WorkspacePaths.child(parent: parent, name: name)
        do {
            try FileManager.default.moveItem(at: url(for: relativePath), to: url(for: destination))
        } catch {
            return String(localized: "Couldn't rename this item.")
        }
        retargetOpenFiles(from: relativePath, to: destination)
        scheduleReload(parent)
        scheduleIndex()
        return nil
    }

    func trash(relativePath: String) throws {
        let open = buffers.keys.filter { $0 == relativePath || $0.hasPrefix(relativePath + "/") }
        for path in open {
            _ = closeTab(path, force: true)
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
            return String(localized: "Couldn't move this item.")
        }
        retargetOpenFiles(from: relativePath, to: destination)
        scheduleReload(WorkspacePaths.parent(of: relativePath))
        scheduleReload(parent)
        scheduleIndex()
        return nil
    }

    func clearQuery() {
        nameQuery = ""
    }

    func openFile(_ node: WorkspaceNode, pin: Bool = false, line: Int? = nil) {
        guard !node.isDirectory else { return }
        revealAncestors(of: node.relativePath)
        let path = node.relativePath
        if let line {
            pendingRevealLine = line
        } else {
            pendingRevealLine = nil
            scrollLink.clearQueuedReveal()
        }
        var strip = tabStrip
        let replaced = strip.open(path, pin: pin)
        tabStrip = strip
        if let replaced {
            release(replaced, save: true)
        }
        selectedPath = path
        if let existing = buffers[path] {
            show(existing)
            return
        }
        let url = url(for: path)
        Task { [weak self] in
            let loaded = await Self.readForEditing(url: url, name: node.name)
            await MainActor.run {
                guard let self, self.tabStrip.contains(path) else { return }
                let open = self.makeBuffer(loaded, relativePath: path, url: url)
                self.buffers[path] = open
                self.watchFile(open)
                self.noteRecent(path)
                if self.tabStrip.activeID == path {
                    self.show(open)
                }
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
        copyString(buffer?.url.path ?? rootURL.path)
    }

    func copyRelativePath(of relativePath: String? = nil) {
        let path = relativePath ?? buffer?.relativePath ?? ""
        copyString(path.isEmpty ? "." : path)
    }

    func closeActiveTab() -> Bool {
        guard let id = tabStrip.activeID else { return false }
        closeTab(id)
        return true
    }

    /// Closes a tab. A tab with unsaved edits that could not be written stays open.
    @discardableResult
    func closeTab(_ id: String, force: Bool = false) -> Bool {
        if let open = buffers[id] {
            open.flush()
            if !force, open.isDirty || open.conflictText != nil {
                show(open)
                return false
            }
        }
        release(id, save: false)
        var strip = tabStrip
        let next = strip.close(id: id)
        tabStrip = strip
        if let next, let open = buffers[next] {
            show(open)
        } else if next == nil {
            buffer = nil
            selectedPath = nil
            previewBridge.send("")
        }
        return true
    }

    @discardableResult
    func selectTab(id: String) -> Bool {
        guard tabStrip.contains(id) else { return false }
        var strip = tabStrip
        _ = strip.open(id, pin: false)
        tabStrip = strip
        selectedPath = id
        revealAncestors(of: id)
        if let open = buffers[id] {
            show(open)
        }
        focusOpenEditor()
        return true
    }

    @discardableResult
    func selectTab(number: Int) -> Bool {
        var strip = tabStrip
        guard let id = strip.select(shortcut: number) else { return false }
        tabStrip = strip
        return selectTab(id: id)
    }

    func revealCrumb(_ relativePath: String) {
        guard !relativePath.isEmpty else { return }
        revealAncestors(of: relativePath)
        guard let node = node(at: relativePath) else { return }
        if node.isDirectory {
            setExpanded(node, true)
            selectedPath = relativePath
        } else {
            openFile(node, pin: true)
        }
    }

    func chooseEncoding(_ encoding: TextEncoding) {
        _ = buffer?.chooseEncoding(encoding)
        objectWillChange.send()
    }

    func chooseLineEnding(_ ending: LineEnding) {
        buffer?.chooseLineEnding(ending)
        objectWillChange.send()
    }

    func focusOpenEditor() {
        DispatchQueue.main.async { [weak self] in
            self?.scrollLink.focusEditor?()
        }
    }

    func copyString(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func show(_ open: WorkspaceFileBuffer) {
        let same = buffer === open
        buffer = open
        selectedPath = open.relativePath
        previewBridge.send(open.text)
        guard let line = pendingRevealLine else { return }
        pendingRevealLine = nil
        if same {
            scrollLink.revealLine(line)
        } else {
            scrollLink.storeQueuedReveal(line)
        }
    }

    private func release(_ path: String, save: Bool) {
        if save {
            buffers[path]?.flush()
        }
        unwatchFile(path)
        buffers[path] = nil
        if buffer?.relativePath == path {
            buffer = nil
        }
    }

    private func makeBuffer(_ loaded: LoadedFile, relativePath: String, url: URL) -> WorkspaceFileBuffer {
        let open = WorkspaceFileBuffer(
            url: url,
            relativePath: relativePath,
            kind: loaded.kind,
            text: loaded.text,
            encoding: loaded.encoding,
            lineEnding: loaded.lineEnding,
            mixedLineEndings: loaded.mixedLineEndings
        )
        open.onEditorState = { [weak self] buffer in
            guard let self else { return }
            var strip = self.tabStrip
            guard strip.setDirty(id: buffer.relativePath, buffer.isDirty) else { return }
            self.tabStrip = strip
        }
        return open
    }

    private func watchFile(_ open: WorkspaceFileBuffer) {
        let path = open.relativePath
        let key = "file:" + path
        monitor.watch(url: open.url, key: key) { [weak open] in
            Task { @MainActor in
                open?.noteExternalChange()
            }
        }
    }

    private func unwatchFile(_ path: String) {
        let key = "file:" + path
        monitor.unwatch(key: key)
    }

    private func retargetOpenFiles(from old: String, to new: String) {
        guard old != new else { return }
        retarget(from: old, to: new)
        var next: [String: WorkspaceFileBuffer] = [:]
        for (path, open) in buffers {
            let mapped = WorkspacePaths.replacing(path, from: old, to: new)
            if mapped != path {
                unwatchFile(path)
                open.retarget(relativePath: mapped, url: url(for: mapped))
                watchFile(open)
            }
            next[mapped] = open
        }
        buffers = next
        var strip = tabStrip
        strip.retarget(from: old, to: new)
        tabStrip = strip
        if let selectedPath {
            self.selectedPath = WorkspacePaths.replacing(selectedPath, from: old, to: new)
        }
        recentPaths = recentPaths.map { WorkspacePaths.replacing($0, from: old, to: new) }
        UserDefaults.standard.set(recentPaths, forKey: Self.recentsKey(for: rootURL))
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
                      let decoded = TextBytes.decode(data, allowLegacy: FileFormats.isTextualName(entry.name)) else { continue }
                let room = min(3, WorkspaceContentSearch.hitLimit - found.count)
                found.append(contentsOf: WorkspaceContentSearch.hits(
                    in: decoded.text,
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
                    let message = String(localized: "Couldn't read this folder.")
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
        for open in buffers.values where WorkspacePaths.parent(of: open.relativePath) == parent {
            if !nodes.contains(where: { $0.relativePath == open.relativePath }) {
                open.noteMissing()
            }
        }
    }

    private struct LoadedFile: Sendable {
        var kind: WorkspaceFileKind
        var text: String
        var encoding: TextEncoding
        var lineEnding: LineEnding
        var mixedLineEndings: Bool
    }

    private static func readForEditing(url: URL, name: String) async -> LoadedFile {
        await Task.detached {
            let empty = LoadedFile(kind: .binary, text: "", encoding: .utf8, lineEnding: .lf, mixedLineEndings: false)
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
                return LoadedFile(kind: kind, text: "", encoding: .utf8, lineEnding: .lf, mixedLineEndings: false)
            }
            let data = (fullFile?.count == size ? fullFile : nil) ?? (try? WorkspaceFileCoordination.readData(at: url))
            guard let data, let decoded = TextBytes.decode(data, allowLegacy: true) else {
                return empty
            }
            return LoadedFile(
                kind: kind,
                text: decoded.text,
                encoding: decoded.encoding,
                lineEnding: decoded.lineEnding,
                mixedLineEndings: decoded.mixedLineEndings
            )
        }.value
    }
}

/// Text for one workspace file. Keystrokes stay here and are written with a coordinated save.
@MainActor
final class WorkspaceFileBuffer: ObservableObject {
    private(set) var url: URL
    private(set) var relativePath: String
    @Published private(set) var kind: WorkspaceFileKind
    @Published private(set) var reloadToken = 0
    @Published private(set) var conflictText: String?
    @Published private(set) var isMissing = false
    @Published private(set) var status: String?
    private(set) var text: String
    private(set) var encoding: TextEncoding
    private(set) var lineEnding: LineEnding
    private(set) var mixedLineEndings: Bool
    var onEditorState: ((WorkspaceFileBuffer) -> Void)?
    private var lastSaved: String
    private var savedEncoding: TextEncoding
    private var savedLineEnding: LineEnding
    private var saveTask: Task<Void, Never>?

    var isDirty: Bool {
        text != lastSaved || encoding != savedEncoding || lineEnding != savedLineEnding
    }

    fileprivate init(
        url: URL,
        relativePath: String,
        kind: WorkspaceFileKind,
        text: String,
        encoding: TextEncoding,
        lineEnding: LineEnding,
        mixedLineEndings: Bool
    ) {
        self.url = url
        self.relativePath = relativePath
        self.kind = kind
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.mixedLineEndings = mixedLineEndings
        self.lastSaved = text
        self.savedEncoding = encoding
        self.savedLineEnding = lineEnding
        Self.nextGeneration += 1
        generation = Self.nextGeneration
    }

    func retarget(relativePath: String, url: URL) {
        self.relativePath = relativePath
        self.url = url
    }

    /// Changes how the next save writes the bytes. Returns false when the text cannot be stored that way.
    @discardableResult
    func chooseEncoding(_ encoding: TextEncoding) -> Bool {
        guard kind == .markdown || kind == .plainText else { return false }
        guard TextBytes.canStore(text, as: encoding) else {
            status = String(localized: "This text can't be stored in that encoding.")
            return false
        }
        self.encoding = encoding
        status = nil
        onEditorState?(self)
        scheduleSave()
        return true
    }

    func chooseLineEnding(_ ending: LineEnding) {
        guard kind == .markdown || kind == .plainText else { return }
        lineEnding = ending
        mixedLineEndings = false
        onEditorState?(self)
        scheduleSave()
    }

    /// Changes when the file is opened or reloaded, so one text view can swap documents.
    var editorToken: Int { generation &+ reloadToken }

    private static var nextGeneration = 0
    private let generation: Int

    func userEdited(_ newText: String) {
        text = newText
        onEditorState?(self)
        if conflictText != nil || isMissing {
            saveTask?.cancel()
            return
        }
        if newText == lastSaved, encoding == savedEncoding, lineEnding == savedLineEnding {
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
        if kind != .markdown && kind != .plainText {
            reloadToken += 1
            return
        }
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
                guard let decoded = TextBytes.decode(data, allowLegacy: true) else {
                    self.kind = .binary
                    self.conflictText = nil
                    self.reloadToken += 1
                    return
                }
                self.encoding = decoded.encoding
                self.lineEnding = decoded.lineEnding
                self.mixedLineEndings = decoded.mixedLineEndings
                self.isMissing = false
                switch WorkspaceFilePolicy.interpretChange(editor: self.text, lastSaved: self.lastSaved, disk: decoded.text) {
                case .ignore:
                    if self.text == decoded.text {
                        self.lastSaved = decoded.text
                    }
                case .reload:
                    self.apply(text: decoded.text)
                case .conflict:
                    self.conflictText = decoded.text
                }
                self.onEditorState?(self)
            }
        }
    }

    func noteMissing() {
        isMissing = true
        if text != lastSaved {
            conflictText = nil
            status = String(localized: "This file was removed. Overwrite to save your edits back.")
        }
    }

    private func apply(text: String) {
        self.text = text
        lastSaved = text
        conflictText = nil
        isMissing = false
        status = nil
        reloadToken += 1
        savedEncoding = encoding
        savedLineEnding = lineEnding
        onEditorState?(self)
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
        let formDirty = encoding != savedEncoding || lineEnding != savedLineEnding
        guard force || text != lastSaved || formDirty else { return }
        let editor = text
        let saved = lastSaved
        do {
            let (decision, disk) = try WorkspaceFileCoordination.updateText(
                at: url,
                editor: editor,
                lastSaved: saved,
                encoding: encoding,
                lineEnding: lineEnding,
                force: force,
                rewrite: formDirty && text == lastSaved
            )
            switch decision {
            case .write:
                lastSaved = editor
                savedEncoding = encoding
                savedLineEnding = lineEnding
                conflictText = nil
                isMissing = false
                status = nil
                onEditorState?(self)
            case .upToDate:
                if let disk, disk == text {
                    lastSaved = disk
                    onEditorState?(self)
                }
            case .conflict:
                conflictText = disk
                status = disk == nil ? String(localized: "This file was removed.") : String(localized: "This file changed on disk.")
            }
        } catch TextBytes.EncodingError.unrepresentable {
            status = String(localized: "Couldn't save this file in its original encoding.")
        } catch {
            status = String(localized: "Couldn't save this file.")
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
