#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

/// Open files for the window. A preview tab is italic. A dirty file has a dot in a fixed slot.
struct EditorTabBar: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.tabStrip.tabs) { tab in
                        EditorTabItem(
                            tab: tab,
                            active: tab.id == session.tabStrip.activeID,
                            select: {
                                _ = session.selectTab(id: tab.id)
                                session.focusOpenEditor()
                            },
                            close: {
                                _ = session.closeTab(tab.id)
                            }
                        )
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: session.tabStrip.activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: 36)
        .background(Color.editorBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
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
            Circle()
                .fill(tab.isDirty ? Color.primary.opacity(active ? 0.9 : 0.38) : Color.clear)
                .frame(width: 6, height: 6)
                .accessibilityLabel(tab.isDirty ? String(localized: "Unsaved") : "")
                .accessibilityHidden(!tab.isDirty)
            Button(action: select) {
                Text(name)
                    .font(titleFont)
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(active ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close Tab"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(minWidth: 120, maxWidth: 200)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.primary.opacity(0.08) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            if active {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.primary.opacity(0.72))
                    .frame(height: 2)
                    .padding(.horizontal, 10)
            }
        }
        .help(tab.id)
    }

    private var name: String {
        (tab.id as NSString).lastPathComponent
    }

    private var titleFont: Font {
        if tab.isPreview {
            return Font.system(size: 12).italic()
        }
        return Font.system(size: 12, weight: active ? .semibold : .regular)
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
                            .font(.system(size: 12, weight: index == crumbs.count - 1 ? .medium : .regular))
                            .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(height: 26)
        .background(Color.editorBackground)
        .background(ScrollElasticityNone())
    }
}

/// Line, selection, encoding, line ending, type, and the word count for prose.
/// Encoding and line ending are menus. They sit in this bar, not in the note.
struct EditorStatusBar: View {
    var caret: EditorCaret?
    var encodingValue: TextEncoding?
    var lineEndingValue: LineEnding?
    var mixedEndings: Bool
    var typeName: String
    var words: TextStatistics?
    var showsReadingTime: Bool
    /// Pixel size, zoom, or PDF page. Empty for text.
    var detail: String? = nil
    var onEncoding: ((TextEncoding) -> Void)?
    var onLineEnding: ((LineEnding) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if let caret {
                statusText(position(caret))
                if let selection = selection(caret) {
                    separator
                    statusText(selection)
                }
            }
            Spacer(minLength: 8)
            if let words {
                statusText(wordLabel(words))
                separator
            }
            if let encodingValue {
                encodingMenu(encodingValue)
                separator
            }
            if let lineEndingValue {
                endingMenu(lineEndingValue)
                separator
            }
            if let detail, !detail.isEmpty {
                statusText(detail)
                separator
            }
            statusText(String(localized: String.LocalizationValue(typeName)))
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(Color.editorBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 6)
    }

    private func statusText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private func encodingMenu(_ current: TextEncoding) -> some View {
        Menu {
            ForEach(TextEncoding.allCases, id: \.self) { item in
                Toggle(isOn: Binding(
                    get: { item == current },
                    set: { isOn in if isOn { onEncoding?(item) } }
                )) {
                    Text(LocalizedStringKey(item.label))
                }
            }
        } label: {
            statusText(String(localized: String.LocalizationValue(current.label)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(onEncoding == nil)
    }

    private func endingMenu(_ current: LineEnding) -> some View {
        Menu {
            ForEach(LineEnding.allCases, id: \.self) { item in
                Toggle(isOn: Binding(
                    get: { item == current && !mixedEndings },
                    set: { isOn in if isOn { onLineEnding?(item) } }
                )) {
                    Text(LocalizedStringKey(item.label))
                }
            }
        } label: {
            statusText(String(localized: String.LocalizationValue(mixedEndings ? "Mixed" : current.label)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(onLineEnding == nil)
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

/// Headings, JSON keys, or declarations for the open file. View → Show Outline.
struct OutlinePane: View {
    var entries: [OutlineEntry]
    var choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if entries.isEmpty {
                Text("No Outline")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            Button {
                                choose(entry.line)
                            } label: {
                                Text(entry.title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.leading, 12 + CGFloat(min(entry.depth, 6)) * 12)
                                    .padding(.trailing, 10)
                                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help(String(format: String(localized: "Ln %lld, Col %lld"), Int64(entry.line), Int64(1)))
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(ScrollElasticityNone())
            }
        }
        .frame(width: 220)
        .background(Color.editorBackground)
    }
}

@MainActor
final class OutlineModel: ObservableObject {
    @Published private(set) var entries: [OutlineEntry] = []
    private var task: Task<Void, Never>?

    func update(text: String, language: SyntaxLanguage) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let next = FileOutline.entries(in: text, language: language)
            guard !Task.isCancelled, let self else { return }
            if self.entries != next {
                self.entries = next
            }
        }
    }
}

enum OutlineSetting {
    static let key = "xyz.view.outline"
}
#endif
