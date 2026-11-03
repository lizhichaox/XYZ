#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

/// Open files for the window. A preview tab is italic. A dirty file has a dot.
struct EditorTabBar: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(session.tabStrip.tabs) { tab in
                    EditorTabItem(
                        tab: tab,
                        active: tab.id == session.tabStrip.activeID,
                        select: {
                            _ = session.selectTab(id: tab.id)
                        },
                        close: {
                            _ = session.closeTab(tab.id)
                        }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(height: 34)
        .background(Color.editorBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
        .background(ScrollElasticityNone())
    }
}

private struct EditorTabItem: View {
    var tab: EditorTab
    var active: Bool
    var select: () -> Void
    var close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if tab.isDirty {
                Circle()
                    .fill(Color.primary.opacity(active ? 0.85 : 0.45))
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(String(localized: "Unsaved"))
            }
            Button(action: select) {
                Text(name)
                    .font(tab.isPreview
                        ? Font.system(size: 12).italic()
                        : Font.system(size: 12, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close Tab"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 92, maxWidth: 200)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.primary.opacity(0.08) : Color.clear)
        )
        .help(tab.id)
    }

    private var name: String {
        (tab.id as NSString).lastPathComponent
    }
}

/// The file's path, from the folder root. Choosing a folder reveals it in the sidebar.
struct EditorBreadcrumb: View {
    var rootName: String
    var relativePath: String
    var choose: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let crumbs = WorkspacePaths.crumbs(rootName: rootName, relativePath: relativePath)
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Text("›")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        choose(crumb.relativePath)
                    } label: {
                        Text(crumb.name)
                            .font(.caption)
                            .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(height: 24)
        .background(Color.editorBackground)
        .background(ScrollElasticityNone())
    }
}

/// Line, selection, encoding, line ending, type, and the word count for prose.
struct EditorStatusBar: View {
    var caret: EditorCaret?
    var encoding: String?
    var lineEnding: String?
    var mixedEndings: Bool
    var typeName: String
    var words: TextStatistics?
    var showsReadingTime: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let caret {
                Text(position(caret))
                if let selection = selection(caret) {
                    Text(selection)
                }
            }
            Spacer(minLength: 8)
            if let words {
                Text(wordLabel(words))
            }
            if let encoding {
                Text(LocalizedStringKey(encoding))
            }
            if let lineEnding {
                Text(LocalizedStringKey(mixedEndings ? "Mixed" : lineEnding))
            }
            Text(LocalizedStringKey(typeName))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(Color.editorBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func position(_ caret: EditorCaret) -> String {
        String(format: String(localized: "Ln %lld, Col %lld"), Int64(caret.line), Int64(caret.column))
    }

    private func selection(_ caret: EditorCaret) -> String? {
        if caret.selectedLines > 1 {
            return String(format: String(localized: "%lld lines selected"), Int64(caret.selectedLines))
        }
        if caret.selectedCharacters > 0 {
            return String(format: String(localized: "%lld selected"), Int64(caret.selectedCharacters))
        }
        return nil
    }

    private func wordLabel(_ stats: TextStatistics) -> String {
        let words = String(localized: "\(stats.total) words")
        guard showsReadingTime, stats.readingMinutes > 0 else { return words }
        return words + " · " + String(localized: "\(stats.readingMinutes) min read")
    }
}

/// Turns off the rubber-band scroll of a SwiftUI `ScrollView` behind this view.
struct ScrollElasticityNone: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { silence(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        silence(nsView)
    }

    private func silence(_ view: NSView) {
        var current: NSView? = view
        while let next = current?.superview {
            if let scroll = next as? NSScrollView {
                scroll.verticalScrollElasticity = .none
                scroll.horizontalScrollElasticity = .none
            }
            current = next
        }
    }
}
#endif
