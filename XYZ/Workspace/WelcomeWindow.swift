#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

/// The start page: shown when launch has no folder to restore, and when the Dock icon
/// brings the app back with no windows. Open a folder, start a note, or pick a recent
/// folder; the app no longer opens a folder panel on its own at launch.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static var isVisible: Bool { window?.isVisible == true }

    static func show() {
        let window = self.window ?? make()
        let wasVisible = window.isVisible
        // A fresh view each time keeps the recent list current after folders were opened.
        window.contentView = NSHostingView(rootView: WelcomeView())
        self.window = window
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // A small start page in the top-left corner, not a full-screen empty sheet.
        if !wasVisible {
            placeAtTopLeft(window)
        }
    }

    private static func placeAtTopLeft(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let margin: CGFloat = 24
        let x = visible.minX + margin
        let y = max(visible.minY + margin, visible.maxY - size.height - margin)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// The page is only for "nothing open"; every workspace open says so.
    static func close() {
        guard let window, window.isVisible else { return }
        window.close()
    }

    /// Launch is done when this runs: keep the page for a normal cold launch, but stay
    /// out of the way when a Finder double-click or `xyz` supplied a document or folder.
    static func showWhenLaunchCompletes() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !isVisible else { return }
            guard WorkspaceWindowController.controllers.isEmpty else { return }
            guard NSDocumentController.shared.documents.isEmpty else { return }
            show()
        }
    }

    private static func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isExcludedFromWindowsMenu = true
        window.contentMinSize = NSSize(width: 680, height: 440)
        window.setContentSize(NSSize(width: 820, height: 560))
        EscapeKey.register(window)
        return window
    }
}

@MainActor
private final class WelcomeModel: ObservableObject {
    struct Recent: Identifiable {
        let id: UUID
        let name: String
        let path: String
        let bookmark: WorkspaceBookmark
    }

    @Published private(set) var recents: [Recent] = []

    init() {
        reload()
    }

    func reload() {
        recents = WorkspaceLibrary.shared.recents.compactMap { bookmark in
            guard let url = try? WorkspaceBookmarks.resolve(bookmark.data),
                  WorkspaceFolders.isDirectory(url) else { return nil }
            let name = url.lastPathComponent.isEmpty ? bookmark.name : url.lastPathComponent
            return Recent(
                id: bookmark.id,
                name: name,
                path: (url.path as NSString).abbreviatingWithTildeInPath,
                bookmark: bookmark
            )
        }
    }

    func openFolder() {
        WorkspaceWindowController.prompt()
    }

    func newFile() {
        NSDocumentController.shared.newDocument(nil)
        WelcomeWindow.close()
    }

    func open(_ recent: Recent) {
        if WorkspaceWindowController.open(bookmark: recent.bookmark) == nil {
            let alert = NSAlert()
            alert.messageText = String(localized: "Could not open this folder.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModalClosingOnEscape()
            reload()
        }
    }
}

private struct WelcomeView: View {
    @StateObject private var model = WelcomeModel()

    var body: some View {
        HStack(spacing: 0) {
            startColumn
                .frame(width: 268)
                .background(Color(nsColor: .xyzSidebar))
            Rectangle()
                .fill(Color(nsColor: .xyzDivider))
                .frame(width: 1)
            recentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.editorBackground)
        }
        .onReceive(WorkspaceLibrary.shared.$recents) { _ in
            model.reload()
        }
    }

    private var startColumn: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            // The mark, version and the same credit line About uses, then the two actions;
            // the whole block is centered in the column.
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 74, height: 74)
                    .accessibilityHidden(true)
                Text(versionLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.xyzSecondaryText)
                    .padding(.top, 12)
                Text("Made by LIZHICHAO with 💗")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.xyzSecondaryText)
                    .lineLimit(1)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 8) {
                    Button(action: model.openFolder) {
                        Label("Open Folder…", systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.xyzAccent)
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                    Button(action: model.newFile) {
                        Label("New File", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut("n", modifiers: .command)
                }
                .padding(.top, 30)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 26)
        .frame(maxHeight: .infinity)
    }

    private var recentColumn: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recent Folders")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.xyzInk)
                        .padding(.leading, 8)

                    if model.recents.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No recent folders")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.xyzSecondaryText)
                            Text("Open a folder to get started.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.xyzSecondaryText)
                        }
                        .padding(.leading, 8)
                        .padding(.top, 18)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.recents) { recent in
                                RecentFolderRow(recent: recent) {
                                    model.open(recent)
                                }
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: geo.size.height, alignment: .center)
            }
        }
    }

    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !short.isEmpty else { return "" }
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

private struct RecentFolderRow: View {
    let recent: WelcomeModel.Recent
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.xyzSecondaryText)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recent.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.xyzInk)
                        .lineLimit(1)
                    Text(recent.path)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.xyzSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? Color(nsColor: .xyzHover) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(recent.path)
    }
}
#endif
