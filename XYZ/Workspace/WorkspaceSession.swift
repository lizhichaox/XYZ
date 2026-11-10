#if os(macOS)
import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import XYZCore

struct TabSwitchState: Equatable {
    var paths: [String]
    var index: Int
}

/// One open folder: a lazy tree plus the file currently in the editor.
@MainActor
final class WorkspaceSession: ObservableObject {
    let rootURL: URL
    let bookmark: Data?
    let displayName: String

    @Published var showsHiddenFiles = true {
        didSet {
            guard showsHiddenFiles != oldValue else { return }
            UserDefaults.standard.set(showsHiddenFiles, forKey: HiddenFilesSetting.key)
            if !contentQuery.pattern.isEmpty {
                scheduleContentSearch()
            }
        }
    }
    @Published private(set) var children: [String: [WorkspaceNode]] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var loadErrors: [String: String] = [:]
    @Published var selectedPath: String?
    /// The row the user last clicked in the sidebar, published or not. A folder click
    /// only moves this: writing `selectedPath` there redrew the whole window body
    /// (editor, preview, outline) on every click and made opening a folder feel slow.
    var clickedPath: String?
    @Published private(set) var buffer: WorkspaceFileBuffer?
    @Published private(set) var tabStrip = EditorTabStrip()
    @Published var rootError: String?
    @Published var actionMessage: String?
    /// The sidebar folder header. Collapsed hides the tree and leaves the header in place.
    @Published var rootExpanded = true
    /// Right-hand Markdown outline for this folder window. On until the user hides it.
    @Published var outlineVisible = true
    /// Width of that outline. Not published: the split view already has the live width.
    /// The outline width the user last chose. `outlineWidthAdjusted` is false until they
    /// drag it, which is when a new outline should fit its content instead.
    var outlineWidth: CGFloat = 220
    private(set) var outlineWidthAdjusted = false
    /// The sidebar width the user last chose; false until they drag it.
    var sidebarWidth: CGFloat = 260
    private(set) var sidebarWidthAdjusted = false
    @Published var nameQuery = "" {
        didSet {
            guard nameQuery != oldValue else { return }
            scheduleContentSearch()
        }
    }
    @Published var includeGlob = "" {
        didSet {
            guard includeGlob != oldValue else { return }
            scheduleContentSearch()
        }
    }
    @Published var excludeGlob = "" {
        didSet {
            guard excludeGlob != oldValue else { return }
            scheduleContentSearch()
        }
    }
    /// Replacement used by Replace All in the folder. It does not rerun the search.
    @Published var folderReplacement = ""
    @Published var contentMatchCase = false {
        didSet {
            guard contentMatchCase != oldValue else { return }
            scheduleContentSearch()
        }
    }
    @Published var contentWholeWord = false {
        didSet {
            guard contentWholeWord != oldValue else { return }
            scheduleContentSearch()
        }
    }
    @Published var contentRegex = false {
        didSet {
            guard contentRegex != oldValue else { return }
            scheduleContentSearch()
        }
    }
    @Published private(set) var contentPatternInvalid = false

    var contentQuery: FindQuery {
        FindQuery(
            pattern: nameQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            matchCase: contentMatchCase,
            wholeWord: contentWholeWord,
            regex: contentRegex
        )
    }
    @Published private(set) var indexedEntries: [WorkspacePathEntry] = []
    @Published private(set) var contentHits: [WorkspaceContentHit] = []
    @Published private(set) var contentSearching = false
    /// Notes in this folder that link to the open note.
    @Published private(set) var backlinks: [Backlink] = []
    @Published private(set) var backlinksLoading = false
    @Published var viewMode: EditorViewMode
    /// The caret in the open file, for the status bar.
    @Published var caret = EditorCaret()
    /// The source line at the top of Reading. Zero until the page reports one.
    @Published private(set) var viewportLine = 0
    /// Reading progress in whole percent, 0...100.
    @Published private(set) var readingProgress = 0
    /// Set when a new item should start inline rename once the row exists.
    var pendingEditPath: String?
    var focusSearchHandler: (() -> Void)?
    /// Another window already has this path. Return true when that window took it.
    var claimExistingFile: ((String) -> Bool)?
    /// Tabs or a tab's view mode changed. The window list is saved from this.
    var onTabsChanged: (() -> Void)?
    /// Move this tab into a new window on the same folder.
    var onMoveTab: ((String) -> Void)?
    @Published var tabSwitch: TabSwitchState?
    private var tabMRU = TabMRU()
    /// One preview for the life of this window. File switches push new text.
    let previewBridge = PreviewBridge(text: "")
    let previewHost = PreviewWebHost()
    let scrollLink = EditorScrollLink()
    private(set) var recentPaths: [String] = []
    private var closedTabs = ClosedTabHistory()

    private let monitor = DirectoryMonitor()
    private var accessStarted = false
    private var didStart = false
    private var buffers: [String: WorkspaceFileBuffer] = [:]
    private var backlinkTask: Task<Void, Never>?
    private var backlinkGeneration = 0
    private var pendingRevealLine: Int?
    /// True while closing or quitting is flushing every buffer. The window shows one
    /// combined alert, so the per-file conflict alert stays quiet.
    private var suppressingConflictAlerts = false
    /// Last line seen for a path in this session, restored when that file is opened again.
    private var scrollMemory: [String: Int] = [:]
    private var pendingRevealNeedle: String?
    private var reloadTasks: [String: Task<Void, Never>] = [:]
    private var loadGeneration: [String: Int] = [:]
    /// One open of a path. A slower read from an earlier open must not replace the buffer.
    private var openRequest: [String: Int] = [:]
    /// The latest open the user asked for. An older read may add a tab, but it must
    /// not bring the editor forward.
    private var openSerial = 0
    /// The background task that rebuilds the saved tabs, so closing the window stops it.
    private var restoreTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    private var indexGeneration = 0

    init(rootURL: URL, bookmark: Data?) {
        self.rootURL = rootURL
        self.bookmark = bookmark
        self.displayName = rootURL.lastPathComponent
        self.viewMode = EditorModeChoice.initial
        self.recentPaths = UserDefaults.standard.stringArray(forKey: Self.recentsKey(for: rootURL)) ?? []
        if UserDefaults.standard.object(forKey: HiddenFilesSetting.key) != nil {
            self.showsHiddenFiles = UserDefaults.standard.bool(forKey: HiddenFilesSetting.key)
        }
        let outlineKey = Self.outlineVisibleKey(for: rootURL)
        if UserDefaults.standard.object(forKey: outlineKey) != nil {
            outlineVisible = UserDefaults.standard.bool(forKey: outlineKey)
        }
        let storedOutlineWidth = UserDefaults.standard.double(forKey: Self.outlineWidthKey(for: rootURL))
        if storedOutlineWidth >= 160 {
            outlineWidth = CGFloat(storedOutlineWidth)
            // Older builds wrote the default back on every resize. Only a value that
            // differs from that default counts as the user's own choice.
            outlineWidthAdjusted = abs(CGFloat(storedOutlineWidth) - 220) > 1
        }
        let storedSidebarWidth = UserDefaults.standard.double(forKey: Self.sidebarWidthKey(for: rootURL))
        if storedSidebarWidth >= 220 {
            sidebarWidth = CGFloat(storedSidebarWidth)
            sidebarWidthAdjusted = true
        }
        scrollLink.onViewportLine = { [weak self] line in
            self?.noteViewportLine(line)
        }
        scrollLink.onReadingProgress = { [weak self] percent in
            self?.noteReadingProgress(percent)
        }
    }

    func noteViewportLine(_ line: Int) {
        let next = max(0, line)
        guard viewportLine != next else { return }
        viewportLine = next
        XYZDiagnostics.note("outline viewport=\(next)")
    }

    func noteReadingProgress(_ percent: Int) {
        let next = min(100, max(0, percent))
        guard readingProgress != next else { return }
        readingProgress = next
    }

    func clearViewportLine() {
        guard viewportLine != 0 else { return }
        viewportLine = 0
        readingProgress = 0
    }

    func toggleOutlinePane() {
        outlineVisible.toggle()
        UserDefaults.standard.set(outlineVisible, forKey: Self.outlineVisibleKey(for: rootURL))
    }

    func rememberOutlineWidth(_ width: CGFloat) {
        let next = min(640, max(160, width))
        outlineWidthAdjusted = true
        guard abs(outlineWidth - next) > 0.5 else { return }
        outlineWidth = next
        UserDefaults.standard.set(Double(next), forKey: Self.outlineWidthKey(for: rootURL))
    }

    func rememberSidebarWidth(_ width: CGFloat) {
        // The window's own cap is 40% of its width, so the stored value must not be
        // tighter than that: a content-fitted width is the user's choice too.
        let next = min(1000, max(220, width))
        sidebarWidthAdjusted = true
        guard abs(sidebarWidth - next) > 0.5 else { return }
        sidebarWidth = next
        UserDefaults.standard.set(Double(next), forKey: Self.sidebarWidthKey(for: rootURL))
    }

    private static func outlineVisibleKey(for url: URL) -> String {
        "xyz.workspace.outline." + token(for: url)
    }

    private static func outlineWidthKey(for url: URL) -> String {
        "xyz.workspace.outline.width." + token(for: url)
    }

    private static func sidebarWidthKey(for url: URL) -> String {
        "xyz.workspace.sidebar.width." + token(for: url)
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

    /// Writes every buffer that changed, then says which ones still hold edits.
    /// A quit or a window close uses the list to ask instead of dropping changes.
    ///
    /// The per-file conflict alert is suppressed here: the caller shows one alert that
    /// lists every file, and a second modal inside a close would be a double prompt.
    func unsavedForClose() -> [WorkspaceFileBuffer] {
        suppressingConflictAlerts = true
        for open in buffers.values {
            open.flush()
        }
        suppressingConflictAlerts = false
        return buffers.values.filter { $0.isDirty }
    }

    /// Shows the first file that could not be saved, so the user can see the banner.
    func presentForClose(_ open: WorkspaceFileBuffer) {
        var strip = tabStrip
        _ = strip.open(open.relativePath, pin: true)
        tabStrip = strip
        show(open)
        focusOpenEditor()
    }

    func shutdown() {
        suppressingConflictAlerts = true
        for open in buffers.values {
            open.flush()
        }
        suppressingConflictAlerts = false
        restoreTask?.cancel()
        restoreTask = nil
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

    /// Set by an explicit reveal. The sidebar consumes it once. A later refresh must not expand again.
    var pendingSidebarReveal = false

    func consumeSidebarReveal() -> Bool {
        let reveal = pendingSidebarReveal
        pendingSidebarReveal = false
        return reveal
    }

    /// Expand every folder above a file so the outline can select and scroll to it.
    func revealAncestors(of relativePath: String) {
        pendingSidebarReveal = true
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

    /// Selected folder, or the folder that contains the selected file. Root when nothing is selected.
    func creationParent() -> String {
        // A folder the user just clicked wins: that is where New File lands.
        if let clicked = clickedPath, node(at: clicked)?.isDirectory == true {
            return ExplorerSection.creationParent(selectedPath: clicked, isDirectory: true)
        }
        let path = selectedPath ?? buffer?.relativePath
        let isDirectory = path.flatMap { node(at: $0)?.isDirectory } ?? false
        return ExplorerSection.creationParent(selectedPath: path, isDirectory: isDirectory)
    }

    /// Re-reads the folders already listed. Expansion is left as the user set it.
    func refreshFileTree() {
        pendingSidebarReveal = false
        load(parent: "")
        for path in expanded.sorted(by: { $0.count < $1.count }) {
            load(parent: path)
        }
        scheduleIndex()
    }

    /// Closes every nested folder. The open file does not expand them again.
    func collapseAllFolders() {
        pendingSidebarReveal = false
        let paths = expanded
        expanded = []
        for path in paths {
            monitor.unwatch(key: path)
            reloadTasks[path]?.cancel()
        }
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
        if mode == .source, let buffer, !EditorModeChoice.canToggle(Self.access(of: buffer)) {
            NSSound.beep()
            return
        }
        let previous = viewMode
        if previous != mode {
            let fallback = viewportLine > 0 ? viewportLine : caret.line
            let line = scrollLink.noteToggle(to: mode, fallbackLine: fallback)
            XYZDiagnostics.note("mode \(previous.rawValue)->\(mode.rawValue) line=\(line)")
        }
        viewMode = mode
        if let id = tabStrip.activeID {
            var strip = tabStrip
            strip.setMode(id: id, mode)
            tabStrip = strip
            onTabsChanged?()
        }
        if previous != viewMode {
            ViewModeLog.changed(from: previous.rawValue, to: viewMode.rawValue, source: source)
        }
    }

    func toggleViewMode(source: String) {
        guard let buffer, let next = EditorModeChoice.toggled(viewMode, access: Self.access(of: buffer)) else {
            NSSound.beep()
            return
        }
        selectViewMode(next, source: source)
    }

    /// Replace and other edits need the editable source. Locked files stay as they are.
    @discardableResult
    func beginEditing(source: String) -> Bool {
        guard let buffer, EditorModeChoice.canToggle(Self.access(of: buffer)) else { return false }
        if viewMode != .source {
            selectViewMode(.source, source: source)
        }
        return true
    }

    static func access(of buffer: WorkspaceFileBuffer) -> EditorFileAccess {
        EditorModeChoice.access(kind: buffer.kind, markdown: buffer.kind == .markdown)
    }

    /// Scans the folder for notes that link to the open note. Runs off the main actor;
    /// a newer note cancels the previous scan.
    func refreshBacklinks() {
        backlinkTask?.cancel()
        backlinkGeneration &+= 1
        let token = backlinkGeneration
        guard let buffer, buffer.kind == .markdown else {
            backlinks = []
            backlinksLoading = false
            return
        }
        let target = buffer.relativePath
        let source = indexedEntries.isEmpty ? flattenedLoadedEntries() : indexedEntries
        let files = source.filter { entry in
            guard !entry.isDirectory else { return false }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            return ext == "md" || ext == "markdown"
        }
        guard !files.isEmpty else {
            backlinks = []
            backlinksLoading = false
            return
        }
        let root = rootURL
        backlinksLoading = true
        backlinkTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                var texts: [(relativePath: String, text: String)] = []
                for entry in files.prefix(500) {
                    let url = entry.relativePath.split(separator: "/").reduce(root) {
                        $0.appendingPathComponent(String($1))
                    }
                    guard WorkspaceFileCoordination.fileSize(at: url) <= 1_000_000 else { continue }
                    guard let data = try? WorkspaceFileCoordination.readData(at: url),
                          let decoded = TextBytes.decode(data, allowLegacy: true) else { continue }
                    texts.append((entry.relativePath, decoded.text))
                }
                return BacklinkIndex.backlinks(to: target, in: texts)
            }.value
            guard !Task.isCancelled, let self, self.backlinkGeneration == token else { return }
            self.backlinks = found
            self.backlinksLoading = false
        }
    }

    func focusSearch() {
        focusSearchHandler?()
    }

    /// A link in Reading. Files in this folder open here; anything else goes to its default app.
    ///
    /// A wiki link such as `[[ST/AGENTS]]` names a path from the folder root, while the
    /// page resolves it against the note's own folder. If that note-relative file is
    /// absent, open the same path from the workspace root instead of a missing file.
    func openLinked(_ url: URL) {
        let root = rootURL.standardizedFileURL
        let rootPath = root.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            NSWorkspace.shared.open(url)
            return
        }
        if !FileManager.default.fileExists(atPath: path),
           let folder = buffer?.url.deletingLastPathComponent().standardizedFileURL,
           let relative = LinkedNotePath.rootRelative(
               linkPath: path,
               noteFolderPath: folder.path,
               rootPath: rootPath,
               isFile: { FileManager.default.fileExists(atPath: $0) }
           ) {
            openRelative(relative)
            return
        }
        openRelative(String(path.dropFirst(rootPath.count + 1)))
    }

    private func rememberScrollLine() {
        guard let path = buffer?.relativePath else { return }
        let line = max(viewportLine, caret.line)
        if line > 1 {
            scrollMemory[path] = line
        }
    }

    func recentOpenPaths() -> [String] {
        tabMRU.order(open: tabStrip.tabs.map(\.id))
    }

    func openSearchHit(relativePath: String, line: Int, needle: String) {
        pendingRevealNeedle = needle
        openRelative(relativePath, pin: true, line: line)
        if pendingRevealLine == nil {
            pendingRevealNeedle = nil
        }
    }

    /// A task checkbox in Reading was clicked. Flip the marker on that source line.
    @discardableResult
    func toggleTask(atLine line: Int, undoManager: UndoManager?) -> String? {
        guard let buffer, buffer.kind == .markdown,
              let toggle = TaskList.toggle(in: buffer.text, line: line) else { return nil }
        buffer.userEdited(toggle.text)
        previewBridge.send(toggle.text)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] session in
            session.toggleTask(atLine: line, undoManager: undoManager)
        }
        undoManager?.setActionName(String(localized: "Toggle Task"))
        return toggle.text
    }

    /// Folder replace from the Edit menu. The count is confirmed before any file changes.
    func replaceInFolder(pattern: String, replacement: String, undoManager: UndoManager?) {
        let query = FindQuery(pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines))
        startFolderReplace(query: query, replacement: replacement, undoManager: undoManager)
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

    /// Creates a new empty file or folder.
    ///
    /// The name is chosen again at the moment of creation, and creation itself never
    /// overwrites. The default APFS volume compares names without case, so a tree
    /// listing alone cannot prove that `Untitled.md` is a free name while `untitled.md`
    /// exists. `Data.write(.withoutOverwriting)` and `createDirectory` fail instead.
    func createItem(directory: Bool, in parent: String) {
        let parentURL = url(for: parent)
        let listed = (children[parent] ?? []).map(\.name)
        let preferred = directory ? "Untitled Folder" : "Untitled.md"
        if !parent.isEmpty {
            Self.makeParentVisible(parent: parent, session: self)
        }
        Task { [weak self] in
            let created = Self.createItemExclusively(
                directory: directory,
                preferred: preferred,
                listed: listed,
                parent: parent,
                parentURL: parentURL
            )
            await MainActor.run {
                guard let self else { return }
                guard let created else {
                    self.actionFailed(String(localized: "Couldn't create this item."))
                    return
                }
                self.pendingEditPath = created.relativePath
                if !directory {
                    self.openFile(WorkspaceNode(
                        name: created.name,
                        relativePath: created.relativePath,
                        isDirectory: false,
                        isHidden: created.name.hasPrefix(".")
                    ), pin: true)
                }
                self.scheduleReload(parent)
                self.scheduleIndex()
            }
        }
    }

    @MainActor
    private static func makeParentVisible(parent: String, session: WorkspaceSession) {
        session.expanded.insert(parent)
        session.rememberExpansion()
        if session.children[parent] == nil {
            session.load(parent: parent)
            session.watchDirectory(parent)
        }
    }

    /// Creates the item, retrying with the next free name when the file system reports
    /// that the chosen path already exists. Returns nil for any other error.
    private static func createItemExclusively(
        directory: Bool,
        preferred: String,
        listed: [String],
        parent: String,
        parentURL: URL
    ) -> (name: String, relativePath: String)? {
        var existing = Set(listed)
        for _ in 0..<20 {
            let onDisk = Set(
                (try? FileManager.default.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil))?
                    .map(\.lastPathComponent) ?? []
            )
            existing.formUnion(onDisk)
            let name = WorkspaceItemName.unique(preferred: preferred, existing: existing)
            let destination = parentURL.appendingPathComponent(name, isDirectory: directory)
            do {
                if directory {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                } else {
                    try Data().write(to: destination, options: .withoutOverwriting)
                }
                return (name, WorkspacePaths.child(parent: parent, name: name))
            } catch {
                guard itemAlreadyExists(error) else { return nil }
                existing.insert(name)
            }
        }
        return nil
    }

    private static func itemAlreadyExists(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            return ns.code == CocoaError.fileWriteFileExists.rawValue
        }
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(EEXIST)
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

    /// Opens a file. Returns the task that installs it when the read has to happen,
    /// so a window restore can wait for one tab before opening the next.
    @discardableResult
    func openFile(
        _ node: WorkspaceNode,
        pin: Bool = false,
        line: Int? = nil,
        mode: EditorViewMode = .reading,
        adoptExisting: Bool = true,
        activate: Bool = true
    ) -> Task<Void, Never>? {
        guard !node.isDirectory else { return nil }
        if adoptExisting, claimExistingFile?(node.relativePath) == true {
            return nil
        }
        let path = node.relativePath
        if buffer?.relativePath != path {
            rememberScrollLine()
        }
        revealAncestors(of: path)
        if let line {
            pendingRevealLine = line
        } else if path != buffer?.relativePath, let saved = scrollMemory[path], saved > 1 {
            pendingRevealLine = saved
        } else {
            pendingRevealLine = nil
            scrollLink.clearQueuedReveal()
        }
        openSerial += 1
        let serial = openSerial
        if let existing = buffers[path] {
            present(path, pin: pin, mode: mode, buffer: existing, activate: activate)
            return nil
        }
        openRequest[path, default: 0] += 1
        let request = openRequest[path] ?? 0
        let url = url(for: path)
        return Task { [weak self] in
            let loaded = await Self.readForEditing(url: url, name: node.name)
            await MainActor.run {
                guard let self else { return }
                let latest = self.openRequest[path] ?? 0
                guard WorkspaceFilePolicy.shouldInstallRead(
                    request: request,
                    latest: latest,
                    alreadyInstalled: self.buffers[path] != nil
                ) else { return }
                let open = self.makeBuffer(loaded, relativePath: path, url: url)
                self.buffers[path] = open
                self.watchFile(open)
                self.noteRecent(path)
                // A tab still lands for every open. Only the latest request the user
                // asked for brings the editor forward; an older read that finishes
                // later must not steal the file the user is already looking at.
                let isLatest = self.openSerial == serial
                self.present(path, pin: pin, mode: mode, buffer: open, activate: activate && isLatest)
            }
        }
    }

    /// The tab and the buffer land together. A tab published first shows the previous note under the new name.
    ///
    /// `activate` is false for tabs that should be restored in the background: the tab
    /// still appears, but the editor keeps the file it already shows.
    private func present(
        _ path: String,
        pin: Bool,
        mode: EditorViewMode,
        buffer: WorkspaceFileBuffer,
        activate: Bool
    ) {
        let previousActive = tabStrip.activeID
        var strip = tabStrip
        // A tab that lands after a newer open must not replace the clean preview tab
        // the user is on, and must not switch the editor. Keep it as a normal tab;
        // the next click on it opens it.
        let replaced = strip.open(path, pin: activate ? pin : true, mode: mode)
        if !activate, let previousActive, previousActive != path, strip.contains(previousActive) {
            strip.setActive(previousActive)
        }
        tabStrip = strip
        onTabsChanged?()
        if let replaced, replaced != path {
            release(replaced, save: true)
        }
        guard activate else { return }
        selectedPath = path
        show(buffer)
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

    func closeOtherTabs(keeping id: String) {
        for other in tabStrip.closableIDs(otherThan: id) {
            _ = closeTab(other)
        }
    }

    func closeAllTabs() {
        for id in tabStrip.closableIDs() {
            _ = closeTab(id)
        }
    }

    func closeTabs(toTheRightOf id: String) {
        for other in tabStrip.closableIDs(toTheRightOf: id) {
            _ = closeTab(other)
        }
    }

    /// Double-click on a preview tab. The file stays, and the title is no longer italic.
    func keepTab(_ id: String) {
        var strip = tabStrip
        strip.pin(id)
        guard strip != tabStrip else { return }
        tabStrip = strip
        onTabsChanged?()
    }

    /// Pin sticks the tab. Unpin leaves it open as a normal tab.
    func setTabPinned(_ id: String, _ pinned: Bool) {
        var strip = tabStrip
        strip.setPinned(id: id, pinned)
        guard strip != tabStrip else { return }
        tabStrip = strip
        onTabsChanged?()
    }

    func revealTabInFinder(_ id: String) {
        NSWorkspace.shared.activateFileViewerSelecting([url(for: id)])
    }

    /// Files and folders next to `relativePath`, already loaded in the tree.
    func siblingNodes(of relativePath: String) -> [WorkspaceNode] {
        let parent = WorkspacePaths.parent(of: relativePath)
        let nodes = children[parent] ?? []
        return WorkspaceTreeSort.ordered(WorkspaceTreeFilter.visible(nodes, showsHidden: showsHiddenFiles))
    }

    func closeActiveTab() -> Bool {
        guard let id = tabStrip.activeID else { return false }
        closeTab(id)
        return true
    }

    /// Closes a tab. A tab with unsaved edits that could not be written stays open.
    @discardableResult
    func closeTab(_ id: String, force: Bool = false) -> Bool {
        if let open = buffers[id], !force, open.isDirty || open.conflictText != nil {
            show(open)
            return false
        }
        var strip = tabStrip
        let next = strip.close(id: id)
        tabStrip = strip
        tabMRU.close(id)
        if !force {
            closedTabs.push(id)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.buffers[id]?.flush()
            self.release(id, save: false)
            if let next, let open = self.buffers[next] {
                self.show(open)
            } else if next == nil {
                self.buffer = nil
                self.selectedPath = nil
                self.previewBridge.send("")
            }
            self.onTabsChanged?()
        }
        return true
    }

    /// Moves a tab out of this window. A tab that could not be saved stays here.
    func detachForMove(_ id: String) -> EditorTab? {
        if let open = buffers[id] {
            open.flush()
            if open.isDirty || open.conflictText != nil {
                show(open)
                return nil
            }
        }
        var strip = tabStrip
        guard let tab = strip.detach(id) else { return nil }
        tabStrip = strip
        tabMRU.close(id)
        release(id, save: false)
        if let next = tabStrip.activeID, let open = buffers[next] {
            show(open)
        } else if tabStrip.activeID == nil {
            buffer = nil
            selectedPath = nil
            previewBridge.send("")
        }
        onTabsChanged?()
        return tab
    }

    func windowState() -> WorkspaceWindowState {
        WorkspaceWindowState(
            tabs: tabStrip.tabs.map {
                WorkspaceTabState(path: $0.id, isPreview: $0.isPreview, mode: $0.mode, isPinned: $0.isPinned)
            },
            activePath: tabStrip.activeID
        ).normalized()
    }

    /// Opens the saved tabs one after another, then ends on the saved active tab.
    ///
    /// The restore used to call `openFile` for every tab in one run loop turn. Each call
    /// took a new global serial, and every read that finished checked it, so only the
    /// last tab could install. The reads are awaited here instead, and each tab is
    /// added with `activate: false`; the saved active tab is selected at the end.
    func restoreTabs(_ state: WorkspaceWindowState) {
        let state = state.normalized()
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for tab in state.tabs where !tab.isPreview {
                guard !Task.isCancelled else { return }
                await self.openRestored(tab)
            }
            for tab in state.tabs where tab.isPreview {
                guard !Task.isCancelled else { return }
                await self.openRestored(tab)
                var strip = self.tabStrip
                strip.setPreview(id: tab.path, true)
                self.tabStrip = strip
            }
            for tab in state.tabs where tab.isPinned {
                guard !Task.isCancelled else { return }
                var strip = self.tabStrip
                strip.setPinned(id: tab.path, true)
                self.tabStrip = strip
            }
            guard !Task.isCancelled else { return }
            if let active = state.activePath {
                _ = self.selectTab(id: active)
            } else if let first = self.tabStrip.tabs.first {
                // A normalized state keeps a selection, but be safe: a tab list with no
                // selected tab would draw an active-looking tab over an empty editor.
                _ = self.selectTab(id: first.id)
            }
            // Do not replace a saved tab list with nothing when every read failed
            // (folder moved, volume gone). Keep the old list for the next launch.
            if !self.tabStrip.tabs.isEmpty || state.tabs.isEmpty {
                self.onTabsChanged?()
            }
            self.restoreTask = nil
        }
    }

    private func openRestored(_ tab: WorkspaceTabState) async {
        let name = (tab.path as NSString).lastPathComponent
        let task = openFile(
            WorkspaceNode(
                name: name,
                relativePath: tab.path,
                isDirectory: false,
                isHidden: WorkspacePaths.isHidden(name: name, resourceHidden: false)
            ),
            pin: true,
            mode: tab.mode,
            adoptExisting: false,
            activate: false
        )
        await task?.value
        var strip = tabStrip
        strip.setMode(id: tab.path, tab.mode)
        tabStrip = strip
    }

    /// Opens the most recently closed tab that is still a file. ⇧⌘T.
    @discardableResult
    func reopenClosedTab() -> Bool {
        while let path = closedTabs.pop() {
            let url = url(for: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            openRelative(path, pin: true)
            return true
        }
        return false
    }

    /// ⌃Tab. The second most recent file is selected. Releasing Control opens it.
    func beginTabSwitch() -> Bool {
        if tabSwitch != nil { return true }
        let order = tabMRU.order(open: tabStrip.tabs.map(\.id))
        guard order.count > 1 else { return false }
        tabSwitch = TabSwitchState(paths: order, index: 1)
        return true
    }

    func moveTabSwitch(_ delta: Int) {
        guard var picker = tabSwitch, !picker.paths.isEmpty else { return }
        let count = picker.paths.count
        picker.index = (picker.index + delta + count) % count
        tabSwitch = picker
    }

    func commitTabSwitch() {
        guard let picker = tabSwitch, picker.paths.indices.contains(picker.index) else {
            tabSwitch = nil
            return
        }
        let path = picker.paths[picker.index]
        tabSwitch = nil
        _ = selectTab(id: path)
    }

    func cancelTabSwitch() {
        tabSwitch = nil
    }

    /// Expands the folders above the active file and selects it in the sidebar.
    func revealActiveFile() {
        guard let path = buffer?.relativePath, !path.isEmpty else { return }
        if !nameQuery.isEmpty {
            nameQuery = ""
        }
        revealAncestors(of: path)
        selectedPath = path
    }

    /// Moves the caret in Source. Reading switches to Source first so the line stays put.
    func revealPosition(line: Int, column: Int) {
        guard let buffer, buffer.kind == .markdown || buffer.kind == .plainText || buffer.kind == .readOnly else { return }
        if EditorModeChoice.showsRenderedPreview(mode: viewMode, access: Self.access(of: buffer)) {
            selectViewMode(.source, source: "goto")
            scrollLink.storeQueuedReveal(line, column: column, editorOnly: true)
        } else {
            scrollLink.revealPosition(line, column)
        }
        focusOpenEditor()
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
        let wasSource = viewMode == .source
        buffer = open
        selectedPath = open.relativePath
        previewBridge.send(open.text)
        refreshBacklinks()
        tabMRU.focus(open.relativePath)
        if let tab = tabStrip.tabs.first(where: { $0.id == open.relativePath }) {
            viewMode = tab.mode
        }
        guard let line = pendingRevealLine else { return }
        if line > 1 {
            viewportLine = line
            XYZDiagnostics.note("outline restore line=\(line)")
        }
        let needle = pendingRevealNeedle
        pendingRevealLine = nil
        pendingRevealNeedle = nil
        if let needle, !needle.isEmpty {
            var strip = tabStrip
            strip.setMode(id: open.relativePath, .source)
            tabStrip = strip
            viewMode = .source
            scrollLink.storeQueuedReveal(line, editorOnly: true, needle: needle)
            if same && wasSource {
                scrollLink.revealMatch?(line, needle)
                scrollLink.clearQueuedReveal()
            }
            return
        }
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
            mixedLineEndings: loaded.mixedLineEndings,
            previewTruncated: loaded.truncated
        )
        open.onEditorState = { [weak self] buffer in
            guard let self else { return }
            var strip = self.tabStrip
            guard strip.setDirty(id: buffer.relativePath, buffer.isDirty) else { return }
            self.tabStrip = strip
        }
        open.onConflict = { [weak self] buffer in
            self?.offerExternalChange(buffer)
        }
        if loaded.missing {
            open.noteMissing()
        }
        open.changeForwarding = open.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return open
    }

    /// A dirty file changed on disk. Reload takes the disk copy. Keep Mine writes the editor over it.
    /// Esc leaves the choice on the banner, and does not write.
    private func offerExternalChange(_ buffer: WorkspaceFileBuffer) {
        guard !suppressingConflictAlerts else { return }
        guard buffer === self.buffer, buffer.conflictText != nil else { return }
        buffer.markConflictOffered()
        let alert = NSAlert()
        alert.messageText = String(localized: "This file changed on disk.")
        alert.informativeText = String(localized: "The copy on disk differs from your edits. Reload replaces your edits. Keep Mine writes your edits over the file.")
        alert.addButton(withTitle: String(localized: "Reload"))
        alert.addButton(withTitle: String(localized: "Keep Mine"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModalClosingOnEscape() {
        case .alertFirstButtonReturn:
            buffer.reloadFromDisk()
        case .alertSecondButtonReturn:
            buffer.overwrite()
        default:
            break
        }
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
        closedTabs.retarget(from: old, to: new)
        tabMRU.retarget(from: old, to: new)
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
            let scan = Task.detached(priority: .utility) {
                WorkspaceIndexScan.entries(at: root)
            }
            // The enumeration checks `Task.isCancelled`, but a detached task does not
            // inherit the cancellation of the task waiting on it. Cancelling the scan
            // is what stops a full-tree walk after the folder window moved on.
            let entries = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            // A stopped scan returns what it had; it must not replace the index.
            guard !Task.isCancelled else { return }
            guard let self, self.indexGeneration == generation else { return }
            self.indexedEntries = entries
            if self.buffer?.kind == .markdown {
                self.refreshBacklinks()
            }
            if !self.nameQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.scheduleContentSearch()
            }
        }
    }

    private func scheduleContentSearch() {
        contentTask?.cancel()
        let query = contentQuery
        let include = includeGlob
        let exclude = excludeGlob
        guard !query.pattern.isEmpty else {
            contentHits = []
            contentSearching = false
            contentPatternInvalid = false
            return
        }
        guard TextFind.isValid(query) else {
            contentHits = []
            contentSearching = false
            contentPatternInvalid = true
            return
        }
        contentPatternInvalid = false
        contentSearching = true
        let files = searchableFiles()
        let root = rootURL
        contentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let hits = await Self.searchContents(
                files: files,
                root: root,
                query: query,
                include: include,
                exclude: exclude
            )
            guard !Task.isCancelled, let self else { return }
            guard self.contentQuery == query, self.includeGlob == include, self.excludeGlob == exclude else { return }
            self.contentHits = hits
            self.contentSearching = false
        }
    }

    /// Replace every match in the folder. Only while Editing. The alert confirms the count. Each file is its own undo.
    func replaceAllInFolder(undoManager: UndoManager?) {
        startFolderReplace(query: contentQuery, replacement: folderReplacement, undoManager: undoManager)
    }

    /// Content hits for the ⌘K panel. Skips hidden files when they are hidden, and skips binary and huge files.
    func searchPanelContents(query find: FindQuery) async -> (hits: [WorkspaceContentHit], more: Int, capped: Bool) {
        let needle = find.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, TextFind.isValid(find) else { return ([], 0, false) }
        let showsHidden = showsHiddenFiles
        var openText: [(String, String)] = []
        var openPaths: Set<String> = []
        for (path, buffer) in buffers {
            guard buffer.kind == .markdown || buffer.kind == .plainText, buffer.conflictText == nil else { continue }
            if !showsHidden, WorkspacePaths.isHidden(name: (path as NSString).lastPathComponent, resourceHidden: false) {
                continue
            }
            openText.append((path, buffer.text))
            openPaths.insert(path)
        }
        let files = indexedEntries.filter { entry in
            !entry.isDirectory
                && !openPaths.contains(entry.relativePath)
                && !WorkspaceContentSearch.shouldSkipRelativePath(entry.relativePath)
                && (showsHidden || !entry.isHidden)
        }
        let cap = 60
        let query = FindQuery(
            pattern: needle,
            matchCase: find.matchCase,
            wholeWord: find.wholeWord,
            regex: find.regex
        )
        var found = await Task.detached(priority: .userInitiated) {
            var hits: [WorkspaceContentHit] = []
            for item in openText {
                if hits.count >= cap { break }
                hits.append(contentsOf: WorkspaceContentSearch.hits(
                    in: item.1,
                    relativePath: item.0,
                    query: query,
                    limit: min(4, cap - hits.count)
                ))
            }
            return hits
        }.value
        if found.count < cap {
            let disk = await Self.searchContents(
                files: files,
                root: rootURL,
                query: query,
                include: "",
                exclude: "",
                cap: cap - found.count,
                perFile: 4
            )
            found.append(contentsOf: disk)
        }
        let shown = Array(found.prefix(40))
        return (shown, found.count - shown.count, found.count >= cap)
    }

    /// The files ⌘K lists and Replace may change: no folders, no skipped
    /// directories, and hidden files only while the sidebar shows them.
    private func searchableFiles() -> [WorkspacePathEntry] {
        indexedEntries.filter {
            guard !$0.isDirectory else { return false }
            guard !WorkspaceContentSearch.shouldSkipRelativePath($0.relativePath) else { return false }
            if !showsHiddenFiles, $0.isHidden { return false }
            return true
        }
    }

    private func startFolderReplace(query: FindQuery, replacement: String, undoManager: UndoManager?) {
        guard let buffer, EditorModeChoice.isEditing(viewMode, access: Self.access(of: buffer)) else {
            NSSound.beep()
            return
        }
        let include = includeGlob
        let exclude = excludeGlob
        guard !query.pattern.isEmpty else {
            actionFailed(String(localized: "No results"))
            return
        }
        guard TextFind.isValid(query) else {
            actionFailed(String(localized: "Invalid"))
            return
        }
        let files = searchableFiles()
        var open: [FolderOpenText] = []
        var blocked: Set<String> = []
        for (path, buffer) in buffers {
            if buffer.kind == .markdown || buffer.kind == .plainText, buffer.conflictText == nil {
                open.append(FolderOpenText(
                    path: path,
                    text: buffer.text,
                    encoding: buffer.encoding,
                    lineEnding: buffer.lineEnding
                ))
            } else {
                blocked.insert(path)
            }
        }
        let root = rootURL
        Task { [weak self] in
            let changes = await Self.planFolderReplace(
                files: files,
                root: root,
                open: open,
                blocked: blocked,
                query: query,
                replacement: replacement,
                include: include,
                exclude: exclude
            )
            await MainActor.run {
                self?.confirmFolderReplace(changes, undoManager: undoManager)
            }
        }
    }

    private func confirmFolderReplace(_ changes: [FolderReplaceChange], undoManager: UndoManager?) {
        let matches = changes.reduce(0) { $0 + $1.count }
        guard matches > 0, !changes.isEmpty else {
            actionFailed(String(localized: "No results"))
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace in Files")
        alert.informativeText = String(
            format: String(localized: "Replace %lld matches in %lld files? Each file can be undone."),
            Int64(matches),
            Int64(changes.count)
        )
        alert.addButton(withTitle: String(localized: "Replace All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModalClosingOnEscape() == .alertFirstButtonReturn else { return }
        var skipped = 0
        for change in changes {
            if !applyFolderChange(change, undoManager: undoManager, restoring: false) {
                skipped += 1
            }
        }
        scheduleContentSearch()
        if skipped > 0 {
            actionFailed(String(format: String(localized: "Skipped %lld files."), Int64(skipped)))
        }
    }

    /// One file, one undo. Returns false when the file was left unchanged.
    @discardableResult
    private func applyFolderChange(
        _ change: FolderReplaceChange,
        undoManager: UndoManager?,
        restoring: Bool
    ) -> Bool {
        let text = restoring ? change.originalText : change.replacedText
        if let buffer = buffers[change.relativePath] {
            guard buffer.kind == .markdown || buffer.kind == .plainText, buffer.conflictText == nil else { return false }
            let expected = restoring ? change.replacedText : change.originalText
            guard buffer.text == expected || restoring else { return false }
            if change.fromBuffer {
                buffer.replaceWholeDocument(text)
            } else if restoring, let data = change.originalData {
                do {
                    try WorkspaceFileCoordination.writeData(data, to: buffer.url)
                } catch {
                    return false
                }
                buffer.adoptDiskText(text)
            } else {
                guard TextBytes.canStore(text, as: change.encoding) else { return false }
                do {
                    try WorkspaceFileCoordination.writeEncodedText(
                        text,
                        encoding: change.encoding,
                        lineEnding: change.lineEnding,
                        to: buffer.url
                    )
                } catch {
                    return false
                }
                buffer.adoptDiskText(text)
            }
        } else if restoring, let data = change.originalData {
            do {
                try WorkspaceFileCoordination.writeData(data, to: url(for: change.relativePath))
            } catch {
                return false
            }
        } else if change.fromBuffer {
            guard TextBytes.canStore(text, as: change.encoding) else { return false }
            do {
                try WorkspaceFileCoordination.writeEncodedText(
                    text,
                    encoding: change.encoding,
                    lineEnding: change.lineEnding,
                    to: url(for: change.relativePath)
                )
            } catch {
                return false
            }
        } else {
            guard TextBytes.canStore(text, as: change.encoding) else { return false }
            do {
                try WorkspaceFileCoordination.writeEncodedText(
                    text,
                    encoding: change.encoding,
                    lineEnding: change.lineEnding,
                    to: url(for: change.relativePath)
                )
            } catch {
                return false
            }
        }
        undoManager?.registerUndo(withTarget: self) { session in
            session.applyFolderChange(change, undoManager: undoManager, restoring: !restoring)
        }
        undoManager?.setActionName(String(localized: "Replace in Files"))
        return true
    }

    private static func searchContents(
        files: [WorkspacePathEntry],
        root: URL,
        query: FindQuery,
        include: String,
        exclude: String,
        cap: Int = WorkspaceContentSearch.hitLimit,
        perFile: Int = 3
    ) async -> [WorkspaceContentHit] {
        let work = Task.detached(priority: .utility) {
            var found: [WorkspaceContentHit] = []
            for entry in files {
                if Task.isCancelled || found.count >= cap { break }
                guard PathGlob.allows(entry.relativePath, include: include, exclude: exclude) else { continue }
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
                let room = min(perFile, cap - found.count)
                found.append(contentsOf: WorkspaceContentSearch.hits(
                    in: decoded.text,
                    relativePath: entry.relativePath,
                    query: query,
                    limit: room
                ))
            }
            return found
        }
        // A detached task does not inherit cancellation from the task that waits on
        // it, so ⌘K closing left the scan reading every remaining file. Cancelling the
        // work task makes the `Task.isCancelled` check inside the loop true.
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func planFolderReplace(
        files: [WorkspacePathEntry],
        root: URL,
        open: [FolderOpenText],
        blocked: Set<String>,
        query: FindQuery,
        replacement: String,
        include: String,
        exclude: String
    ) async -> [FolderReplaceChange] {
        let work = Task.detached(priority: .utility) {
            let openByPath = Dictionary(uniqueKeysWithValues: open.map { ($0.path, $0) })
            var changes: [FolderReplaceChange] = []
            for entry in files {
                if Task.isCancelled { break }
                guard PathGlob.allows(entry.relativePath, include: include, exclude: exclude) else { continue }
                if blocked.contains(entry.relativePath) { continue }
                if let buffer = openByPath[entry.relativePath] {
                    let replaced = TextFind.replaceAll(in: buffer.text, query: query, with: replacement)
                    guard replaced.count > 0 else { continue }
                    guard TextBytes.canStore(replaced.text, as: buffer.encoding) else { continue }
                    changes.append(FolderReplaceChange(
                        relativePath: entry.relativePath,
                        originalText: buffer.text,
                        replacedText: replaced.text,
                        count: replaced.count,
                        encoding: buffer.encoding,
                        lineEnding: buffer.lineEnding,
                        originalData: nil,
                        fromBuffer: true
                    ))
                    continue
                }
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
                let replaced = TextFind.replaceAll(in: decoded.text, query: query, with: replacement)
                guard replaced.count > 0 else { continue }
                guard TextBytes.canStore(replaced.text, as: decoded.encoding) else { continue }
                changes.append(FolderReplaceChange(
                    relativePath: entry.relativePath,
                    originalText: decoded.text,
                    replacedText: replaced.text,
                    count: replaced.count,
                    encoding: decoded.encoding,
                    lineEnding: decoded.lineEnding,
                    originalData: data,
                    fromBuffer: false
                ))
            }
            return changes
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func token(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func expansionKey(for url: URL) -> String {
        "xyz.workspace.expansion." + token(for: url)
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
                    let listingChanged = self.children[parent] != nodes
                    self.children[parent] = nodes
                    self.loadErrors[parent] = nil
                    if parent.isEmpty {
                        self.rootError = nil
                        WorkspaceLog.rootEnumerated(path: self.rootURL.path, count: nodes.count)
                    }
                    self.noteOpenFileStillPresent(parent: parent, nodes: nodes)
                    // Every successful load used to walk the whole tree again. A reload
                    // that found the same names does not change the index, and a changed
                    // one only replaces that folder's direct entries in place.
                    if listingChanged {
                        if self.indexedEntries.isEmpty {
                            self.scheduleIndex()
                        } else {
                            self.indexedEntries = WorkspaceIndexPatch.replacing(
                                entries: self.indexedEntries,
                                parent: parent,
                                children: nodes.map {
                                    WorkspacePathEntry(
                                        name: $0.name,
                                        relativePath: $0.relativePath,
                                        isDirectory: $0.isDirectory,
                                        isHidden: $0.isHidden
                                    )
                                }
                            )
                            if self.buffer?.kind == .markdown {
                                self.refreshBacklinks()
                            }
                        }
                    }
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

    fileprivate struct LoadedFile: Sendable {
        var kind: WorkspaceFileKind
        var text: String
        var encoding: TextEncoding
        var lineEnding: LineEnding
        var mixedLineEndings: Bool
        var truncated = false
        /// The name is text, but the file could not be read. Open an empty editor that
        /// says the file was removed instead of a Quick Look placeholder.
        var missing = false
    }

    fileprivate static func readForEditing(url: URL, name: String) async -> LoadedFile {
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
            let kind = WorkspaceFileClassifier.kind(
                name: name,
                byteCount: size,
                sample: sample,
                fullFile: fullFile
            )
            switch FileOpenRouting.route(name: name, kind: kind) {
            case .edit:
                let data = (fullFile?.count == size ? fullFile : nil) ?? (try? WorkspaceFileCoordination.readData(at: url))
                guard let data else {
                    return LoadedFile(
                        kind: kind,
                        text: "",
                        encoding: .utf8,
                        lineEnding: .lf,
                        mixedLineEndings: false,
                        missing: true
                    )
                }
                guard let decoded = TextBytes.decode(data, allowLegacy: true) else {
                    return empty
                }
                return LoadedFile(
                    kind: kind,
                    text: decoded.text,
                    encoding: decoded.encoding,
                    lineEnding: decoded.lineEnding,
                    mixedLineEndings: decoded.mixedLineEndings
                )
            case .viewer, .quickLook:
                return LoadedFile(kind: .binary, text: "", encoding: .utf8, lineEnding: .lf, mixedLineEndings: false)
            case .readOnlyPreview:
                let limit = TextBytes.previewByteLimit
                let data = (try? WorkspaceFileCoordination.readSample(at: url, limit: limit)) ?? Data()
                let preview = TextBytes.preview(data, truncated: size > data.count)
                return LoadedFile(
                    kind: .readOnly,
                    text: preview.text,
                    encoding: preview.encoding,
                    lineEnding: .lf,
                    mixedLineEndings: false,
                    truncated: preview.truncated
                )
            }
        }.value
    }
}

private struct FolderOpenText: Sendable {
    var path: String
    var text: String
    var encoding: TextEncoding
    var lineEnding: LineEnding
}

private struct FolderReplaceChange: Sendable {
    var relativePath: String
    var originalText: String
    var replacedText: String
    var count: Int
    var encoding: TextEncoding
    var lineEnding: LineEnding
    var originalData: Data?
    var fromBuffer: Bool
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
    var onConflict: ((WorkspaceFileBuffer) -> Void)?
    /// Forwards `@Published` changes (status, conflict, kind, reload) to the session.
    /// The folder window observes the session, not this buffer, so without this a clean
    /// file reloaded from disk or a failed save would not redraw the note or banner.
    var changeForwarding: AnyCancellable?
    private var offeredConflict: String?
    private var lastSaved: String
    private var savedEncoding: TextEncoding
    private var savedLineEnding: LineEnding
    private var saveTask: Task<Void, Never>?
    /// Edits and saves advance this. A disk sample from an older value is dropped.
    private var observationEpoch = 0

    var isDirty: Bool {
        if kind == .readOnly { return false }
        return text != lastSaved || encoding != savedEncoding || lineEnding != savedLineEnding
    }

    /// A read-only preview stopped at `TextBytes.previewByteLimit`.
    private(set) var previewTruncated: Bool

    fileprivate init(
        url: URL,
        relativePath: String,
        kind: WorkspaceFileKind,
        text: String,
        encoding: TextEncoding,
        lineEnding: LineEnding,
        mixedLineEndings: Bool,
        previewTruncated: Bool = false
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
        self.previewTruncated = previewTruncated
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

    /// A folder replace edited this buffer. One assignment, then the normal save.
    func replaceWholeDocument(_ newText: String) {
        guard kind == .markdown || kind == .plainText, conflictText == nil else { return }
        text = newText
        reloadToken += 1
        onEditorState?(self)
        if newText == lastSaved, encoding == savedEncoding, lineEnding == savedLineEnding {
            saveTask?.cancel()
            return
        }
        scheduleSave()
    }

    /// The bytes were written directly. Match them without scheduling another save.
    func adoptDiskText(_ newText: String) {
        saveTask?.cancel()
        text = newText
        lastSaved = newText
        savedEncoding = encoding
        savedLineEnding = lineEnding
        conflictText = nil
        offeredConflict = nil
        isMissing = false
        status = nil
        reloadToken += 1
        onEditorState?(self)
    }

    func userEdited(_ newText: String) {
        if kind == .readOnly { return }
        observationEpoch += 1
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
        if kind == .readOnly {
            let url = url
            let name = url.lastPathComponent
            let epoch = observationEpoch
            Task { [weak self] in
                let loaded = await WorkspaceSession.readForEditing(url: url, name: name)
                await MainActor.run {
                    guard let self, self.kind == .readOnly else { return }
                    guard WorkspaceFilePolicy.isCurrentObservation(started: epoch, current: self.observationEpoch) else { return }
                    self.text = loaded.text
                    self.lastSaved = loaded.text
                    self.encoding = loaded.encoding
                    self.previewTruncated = loaded.truncated
                    self.reloadToken += 1
                }
            }
            return
        }
        if kind != .markdown && kind != .plainText {
            reloadToken += 1
            return
        }
        let url = url
        let epoch = observationEpoch
        Task { [weak self] in
            let data = try? await Task.detached {
                try WorkspaceFileCoordination.readData(at: url)
            }.value
            await MainActor.run {
                guard let self else { return }
                guard WorkspaceFilePolicy.isCurrentObservation(started: epoch, current: self.observationEpoch) else { return }
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
                    self.publishConflict(decoded.text)
                }
                self.onEditorState?(self)
            }
        }
    }

    func noteMissing() {
        isMissing = true
        if text != lastSaved {
            conflictText = nil
            offeredConflict = nil
            status = String(localized: "This file was removed. Overwrite to save your edits back.")
        }
    }

    func markConflictOffered() {
        offeredConflict = conflictText
    }

    /// Records a disk copy that disagrees with unsaved edits. The same text is not offered twice.
    private func publishConflict(_ text: String?) {
        if text == nil {
            offeredConflict = nil
        }
        let changed = conflictText != text
        conflictText = text
        guard changed, let text, text != offeredConflict else { return }
        onConflict?(self)
    }

    private func apply(text: String) {
        observationEpoch += 1
        self.text = text
        lastSaved = text
        conflictText = nil
        offeredConflict = nil
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
        // Synchronous on purpose: `unsavedForClose`, `shutdown`, tab close and tab move
        // check `isDirty` immediately after `flush()`, and a background write here made
        // those checks race the disk.
        observationEpoch += 1
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
                offeredConflict = nil
                isMissing = false
                status = nil
                onEditorState?(self)
                if WorkspaceFilePolicy.needsFollowUpSave(written: editor, current: text) {
                    scheduleSave()
                }
            case .upToDate:
                if let disk, disk == text {
                    lastSaved = disk
                    onEditorState?(self)
                }
            case .conflict:
                publishConflict(disk)
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
