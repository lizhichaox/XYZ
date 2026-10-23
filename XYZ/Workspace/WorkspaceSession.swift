#if os(macOS)
import Combine
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

    private let monitor = DirectoryMonitor()
    private var accessStarted = false
    private var didStart = false
    private var fileWatchKey: String?
    private var reloadTasks: [String: Task<Void, Never>] = [:]
    private var loadGeneration: [String: Int] = [:]

    init(rootURL: URL, bookmark: Data?) {
        self.rootURL = rootURL
        self.bookmark = bookmark
        self.displayName = rootURL.lastPathComponent
    }

    func activate() {
        guard !didStart else { return }
        didStart = true
        accessStarted = rootURL.startAccessingSecurityScopedResource()
        load(parent: "")
        monitor.watch(url: rootURL, key: "") { [weak self] in
            Task { @MainActor in
                self?.scheduleReload("")
            }
        }
    }

    func shutdown() {
        buffer?.flush()
        monitor.stop()
        reloadTasks.values.forEach { $0.cancel() }
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

    func setExpanded(_ node: WorkspaceNode, _ isExpanded: Bool) {
        guard node.isDirectory else { return }
        if isExpanded {
            expanded.insert(node.relativePath)
            if children[node.relativePath] == nil {
                load(parent: node.relativePath)
            }
            monitor.watch(url: url(for: node.relativePath), key: node.relativePath) { [weak self] in
                Task { @MainActor in
                    self?.scheduleReload(node.relativePath)
                }
            }
        } else {
            collapse(node.relativePath)
        }
    }

    func openFile(_ node: WorkspaceNode) {
        guard !node.isDirectory else { return }
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
            }
        }
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
            let sample = (try? WorkspaceFileCoordination.readSample(at: url, limit: WorkspaceFileClassifier.sampleLimit)) ?? Data()
            var kind = WorkspaceFileClassifier.kind(name: name, byteCount: size, sample: sample)
            guard kind == .markdown || kind == .plainText else {
                return LoadedFile(kind: kind, text: "")
            }
            guard let data = try? WorkspaceFileCoordination.readData(at: url),
                  !data.contains(0),
                  let text = String(data: data, encoding: .utf8)
            else {
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
    }

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
#endif
