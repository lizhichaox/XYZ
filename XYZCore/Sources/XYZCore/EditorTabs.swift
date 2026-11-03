import Foundation

/// One open file in a window.
///
/// A preview tab is replaced by the next file opened from a single click.
/// Editing, or opening with `pin`, keeps the tab.
public struct EditorTab: Equatable, Sendable, Identifiable {
    public var id: String
    public var isPreview: Bool
    public var isDirty: Bool
    /// Source or Reading for this tab. Each tab keeps its own mode.
    public var mode: EditorViewMode

    public init(id: String, isPreview: Bool, isDirty: Bool = false, mode: EditorViewMode = .reading) {
        self.id = id
        self.isPreview = isPreview
        self.isDirty = isDirty
        self.mode = mode
    }
}

/// The open tabs of one window, and which one is in front.
public struct EditorTabStrip: Equatable, Sendable {
    public private(set) var tabs: [EditorTab]
    public private(set) var activeID: String?

    public init(tabs: [EditorTab] = [], activeID: String? = nil) {
        self.tabs = tabs
        self.activeID = activeID
    }

    public func contains(_ id: String) -> Bool {
        tabs.contains { $0.id == id }
    }

    /// Opens `id`. A single click (`pin == false`) replaces the current clean preview tab in place.
    /// A dirty preview is pinned instead of replaced. Returns the path of a preview that was removed.
    /// An existing tab keeps the mode it already has.
    @discardableResult
    public mutating func open(_ id: String, pin: Bool, mode: EditorViewMode = .reading) -> String? {
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            activeID = id
            if pin { tabs[index].isPreview = false }
            return nil
        }
        if !pin, let preview = tabs.firstIndex(where: { $0.isPreview }) {
            if tabs[preview].isDirty {
                tabs[preview].isPreview = false
            } else {
                let replaced = tabs[preview].id
                tabs[preview] = EditorTab(id: id, isPreview: true, isDirty: false, mode: mode)
                activeID = id
                return replaced
            }
        }
        tabs.append(EditorTab(id: id, isPreview: !pin, mode: mode))
        activeID = id
        return nil
    }

    public mutating func setMode(id: String, _ mode: EditorViewMode) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].mode = mode
    }

    public mutating func setPreview(id: String, _ preview: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPreview = preview
    }

    /// Removes a tab, the way close does, and hands it back so another window can take it.
    public mutating func detach(_ id: String) -> EditorTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs[index]
        tabs.remove(at: index)
        if activeID == id {
            if tabs.isEmpty {
                activeID = nil
            } else {
                activeID = tabs[min(index, tabs.count - 1)].id
            }
        }
        return tab
    }

    public mutating func pin(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPreview = false
    }

    /// Updates the dirty dot. A dirty tab is pinned. Returns whether the strip changed.
    @discardableResult
    public mutating func setDirty(id: String, _ dirty: Bool) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let wasPreview = tabs[index].isPreview
        if tabs[index].isDirty == dirty, !(dirty && wasPreview) { return false }
        tabs[index].isDirty = dirty
        if dirty { tabs[index].isPreview = false }
        return true
    }

    /// Every tab except `id`, in strip order.
    public func ids(otherThan id: String) -> [String] {
        tabs.map(\.id).filter { $0 != id }
    }

    /// Tabs to the right of `id`. Empty when `id` is missing or last.
    public func ids(toTheRightOf id: String) -> [String] {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        return tabs.dropFirst(index + 1).map(\.id)
    }

    /// Closes a tab and selects the neighbor to its right, or the one to its left.
    @discardableResult
    public mutating func close(id: String) -> String? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return activeID }
        let closingActive = activeID == id
        tabs.remove(at: index)
        if closingActive {
            if tabs.isEmpty {
                activeID = nil
            } else {
                activeID = tabs[min(index, tabs.count - 1)].id
            }
        }
        return activeID
    }

    /// ⌘1 through ⌘8 select that tab. ⌘9 selects the last tab.
    @discardableResult
    public mutating func select(shortcut number: Int) -> String? {
        guard !tabs.isEmpty else { return nil }
        let index: Int
        if number == 9 {
            index = tabs.count - 1
        } else if (1...8).contains(number), number <= tabs.count {
            index = number - 1
        } else {
            return nil
        }
        activeID = tabs[index].id
        return activeID
    }

    public mutating func retarget(from old: String, to new: String) {
        guard !old.isEmpty, old != new else { return }
        for index in tabs.indices {
            tabs[index].id = WorkspacePaths.replacing(tabs[index].id, from: old, to: new)
        }
        if let activeID {
            self.activeID = WorkspacePaths.replacing(activeID, from: old, to: new)
        }
    }
}

/// Paths of tabs closed in one window, most recent first.
public struct ClosedTabHistory: Equatable, Sendable {
    public static let limit = 25
    public private(set) var paths: [String]

    public init(paths: [String] = []) {
        self.paths = paths
    }

    public mutating func push(_ path: String) {
        guard !path.isEmpty else { return }
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit {
            paths.removeLast(paths.count - Self.limit)
        }
    }

    public mutating func pop() -> String? {
        guard !paths.isEmpty else { return nil }
        return paths.removeFirst()
    }

    /// A rename of an open item also rewrites paths waiting to be reopened.
    public mutating func retarget(from old: String, to new: String) {
        guard !old.isEmpty, old != new else { return }
        var seen = Set<String>()
        var next: [String] = []
        next.reserveCapacity(paths.count)
        for path in paths {
            let mapped = WorkspacePaths.replacing(path, from: old, to: new)
            if seen.insert(mapped).inserted {
                next.append(mapped)
            }
        }
        paths = next
    }
}

/// One tab to restore with a window.
public struct WorkspaceTabState: Equatable, Codable, Sendable {
    public var path: String
    public var isPreview: Bool
    public var mode: EditorViewMode

    public init(path: String, isPreview: Bool, mode: EditorViewMode) {
        self.path = path
        self.isPreview = isPreview
        self.mode = mode
    }
}

/// The tabs of one workspace window.
public struct WorkspaceWindowState: Equatable, Codable, Sendable {
    public var tabs: [WorkspaceTabState]
    public var activePath: String?

    public init(tabs: [WorkspaceTabState], activePath: String?) {
        self.tabs = tabs
        self.activePath = activePath
    }

    /// Drops empty and repeated paths. At most one tab stays a preview. The active path has to be one of the tabs.
    public func normalized() -> WorkspaceWindowState {
        var seen = Set<String>()
        var kept: [WorkspaceTabState] = []
        kept.reserveCapacity(tabs.count)
        for tab in tabs {
            guard !tab.path.isEmpty, seen.insert(tab.path).inserted else { continue }
            kept.append(tab)
        }
        if let preview = kept.firstIndex(where: { $0.isPreview && $0.path == activePath })
            ?? kept.firstIndex(where: { $0.isPreview }) {
            for index in kept.indices where index != preview {
                kept[index].isPreview = false
            }
        }
        let active = activePath.flatMap { path in kept.contains(where: { $0.path == path }) ? path : nil }
        return WorkspaceWindowState(tabs: kept, activePath: active)
    }
}

/// Where a file is already open, so a second window does not take another copy.
public enum WorkspaceFileFocus {
    /// The other window that already has `path`. The current window keeps a file it already shows.
    public static func otherWindow(containing path: String, tabs: [[String]], current: Int) -> Int? {
        guard !path.isEmpty else { return nil }
        if tabs.indices.contains(current), tabs[current].contains(path) {
            return nil
        }
        for (index, window) in tabs.enumerated() where index != current {
            if window.contains(path) { return index }
        }
        return nil
    }
}

/// Most recently focused tabs in one window, newest first.
public struct TabMRU: Equatable, Sendable {
    public private(set) var recent: [String]

    public init(recent: [String] = []) {
        self.recent = recent
    }

    public mutating func focus(_ path: String) {
        guard !path.isEmpty else { return }
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
    }

    public mutating func close(_ path: String) {
        recent.removeAll { $0 == path }
    }

    public mutating func retarget(from old: String, to new: String) {
        guard !old.isEmpty, old != new else { return }
        var seen = Set<String>()
        var next: [String] = []
        for path in recent {
            let mapped = WorkspacePaths.replacing(path, from: old, to: new)
            if seen.insert(mapped).inserted {
                next.append(mapped)
            }
        }
        recent = next
    }

    /// Open tabs, most recently focused first. Tabs that were never focused follow in `open` order.
    public func order(open: [String]) -> [String] {
        let known = Set(open)
        var result = recent.filter { known.contains($0) }
        for path in open where !result.contains(path) {
            result.append(path)
        }
        return result
    }
}
