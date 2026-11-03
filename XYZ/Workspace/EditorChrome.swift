#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

enum FindBarAction {
    case refresh
    case next
    case previous
    case replaceOne
    case replaceAll
    case useSelection
    case selectNextOccurrence
    case focus
}

@MainActor
final class EditorFindModel: ObservableObject {
    @Published var pattern = ""
    @Published var replacement = ""
    @Published var visible = false
    @Published var showsReplace = false
    @Published var matchCase = false
    @Published var wholeWord = false
    @Published var regex = false
    @Published var regexInvalid = false
    @Published var index = 0
    @Published var count = 0
    @Published var focusToken = 0
    var language: SyntaxLanguage = .plain
    var perform: ((FindBarAction) -> Void)?
    var edit: (((String, SourceRange) -> SourceReplacement?) -> Void)?

    var query: FindQuery {
        FindQuery(pattern: pattern, matchCase: matchCase, wholeWord: wholeWord, regex: regex)
    }

    func show(replace: Bool) {
        visible = true
        if replace { showsReplace = true }
        perform?(.focus)
        perform?(.refresh)
    }

    func replacementText(for text: String, match: FindMatch) -> String {
        TextFind.replacement(in: text, match: match, query: query, with: replacement)
    }
}

struct EditorFindBar: View {
    @ObservedObject var model: EditorFindModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Find", text: $model.pattern)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { model.perform?(.next) }
                toggle("Aa", help: "Match Case", on: $model.matchCase)
                toggle("W", help: "Whole Word", on: $model.wholeWord)
                toggle(".*", help: "Regex", on: $model.regex)
                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(model.regexInvalid ? Color.red.opacity(0.8) : Color.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: .trailing)
                Button("↑") { model.perform?(.previous) }
                    .buttonStyle(.borderless)
                    .help("Find Previous")
                    .accessibilityLabel("Find Previous")
                Button("↓") { model.perform?(.next) }
                    .buttonStyle(.borderless)
                    .help("Find Next")
                    .accessibilityLabel("Find Next")
                Button("Close") { model.visible = false }.buttonStyle(.borderless)
            }
            if model.showsReplace {
                HStack(spacing: 6) {
                    TextField("Replace", text: $model.replacement)
                        .textFieldStyle(.roundedBorder)
                    Button("Replace") { model.perform?(.replaceOne) }
                        .buttonStyle(.borderless)
                        .disabled(model.count == 0)
                    Button("Replace All") { model.perform?(.replaceAll) }
                        .buttonStyle(.borderless)
                        .disabled(model.count == 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.editorBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
        .onAppear { focused = true }
        .onChange(of: model.pattern) { _, _ in model.perform?(.refresh) }
        .onChange(of: model.matchCase) { _, _ in model.perform?(.refresh) }
        .onChange(of: model.wholeWord) { _, _ in model.perform?(.refresh) }
        .onChange(of: model.regex) { _, _ in model.perform?(.refresh) }
        .onChange(of: model.focusToken) { _, _ in focused = true }
    }

    private var countLabel: String {
        if model.pattern.isEmpty { return "" }
        if model.regexInvalid { return String(localized: "Invalid") }
        if model.count == 0 { return String(localized: "No results") }
        return String(format: String(localized: "%lld of %lld"), Int64(model.index), Int64(model.count))
    }

    private func toggle(_ title: String, help: String, on: Binding<Bool>) -> some View {
        Button(title) { on.wrappedValue.toggle() }
            .buttonStyle(.borderless)
            .foregroundStyle(on.wrappedValue ? Color.primary : Color.secondary)
            .help(String(localized: String.LocalizationValue(help)))
    }
}

/// Open files for the window. A preview tab is italic. A dirty file has a dot in a fixed slot.
struct EditorTabBar: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
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
                            },
                            move: {
                                session.onMoveTab?(tab.id)
                            }
                        )
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .layoutPriority(1)
            WindowDragRegion()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            .onChange(of: session.tabStrip.activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: 30)
        .background(WindowDragRegion())
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
    var move: () -> Void

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
        .frame(height: 22)
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
        .contextMenu {
            Button("Move to New Window") {
                move()
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 28).onEnded { value in
                if abs(value.translation.height) > 48 {
                    move()
                }
            }
        )
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
            .padding(.horizontal, 10)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(height: 22)
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
        .padding(.horizontal, 8)
        .frame(height: 22)
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

/// Empty title-bar space. A drag moves the window. A double click follows the system's title-bar setting.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize":
                    window.miniaturize(nil)
                case "None":
                    break
                default:
                    window.zoom(nil)
                }
                return
            }
            window.performDrag(with: event)
        }
    }
}

/// ⌃Tab. A transient list of the window's open files, most recent first.
struct TabSwitchPicker: View {
    var paths: [String]
    var index: Int
    var choose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(paths.enumerated()), id: \.offset) { offset, path in
                Button {
                    choose(offset)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(name(path))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let directory = directory(path) {
                                Text(directory)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .background(offset == index ? Color.primary.opacity(0.12) : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 420)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func directory(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }
}
#endif
