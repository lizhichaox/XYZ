import Foundation

/// One open file in a window.
///
/// A preview tab is replaced by the next file opened from a single click.
/// Editing, or opening with `pin`, keeps the tab.
public struct EditorTab: Equatable, Sendable, Identifiable {
    public var id: String
    public var isPreview: Bool
    public var isDirty: Bool

    public init(id: String, isPreview: Bool, isDirty: Bool = false) {
        self.id = id
        self.isPreview = isPreview
        self.isDirty = isDirty
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
    @discardableResult
    public mutating func open(_ id: String, pin: Bool) -> String? {
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
                tabs[preview] = EditorTab(id: id, isPreview: true, isDirty: false)
                activeID = id
                return replaced
            }
        }
        tabs.append(EditorTab(id: id, isPreview: !pin))
        activeID = id
        return nil
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
