#if os(macOS)
import AppKit
import SwiftUI
import WebKit
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
    case cancel
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
    @Published var wrapped = false
    @Published var focusToken = 0
    var language: SyntaxLanguage = .plain
    var perform: ((FindBarAction) -> Void)?
    var edit: (((String, SourceRange) -> SourceReplacement?) -> Void)?
    weak var editorView: XYZMacTextView?
    var surface: FindSurface = .editor
    weak var readingWeb: WKWebView?
    var readingText: () -> String = { "" }
    private var searchTask: Task<Void, Never>?
    private var readingCursor = 0
    private var readingGeneration = 0

    enum FindSurface {
        case editor
        case reading
    }

    init() {
        perform = { [weak self] action in
            self?.dispatch(action)
        }
    }

    var query: FindQuery {
        FindQuery(pattern: pattern, matchCase: matchCase, wholeWord: wholeWord, regex: regex)
    }

    func useEditor() {
        surface = .editor
    }

    func useReading(_ web: WKWebView?, text: @escaping () -> String) {
        surface = .reading
        readingWeb = web
        readingText = text
    }

    func dismiss() {
        XYZDiagnostics.note("find close replace=\(showsReplace)")
        searchTask?.cancel()
        visible = false
        wrapped = false
        perform?(.cancel)
    }

    func show(replace: Bool) {
        XYZDiagnostics.note("find open replace=\(replace)")
        let reopen = visible
        visible = true
        if replace { showsReplace = true }
        if !reopen {
            adoptSelection()
        }
        focusToken &+= 1
        scheduleRefresh()
    }

    func dispatch(_ action: FindBarAction) {
        if surface == .reading {
            runReading(action)
        } else {
            editorView?.runFind(action)
        }
    }

    private func adoptSelection() {
        if let editor = editorView, editor.window != nil, let seed = editor.singleLineSelection() {
            pattern = seed
            return
        }
        guard surface == .reading, let web = readingWeb else { return }
        web.evaluateJavaScript("window.getSelection().toString()") { [weak self] value, _ in
            guard let self, let text = value as? String else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r"), trimmed.count < 2_000 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { () -> Void in
                    self.pattern = trimmed
                }
            }
        }
    }

    private func runReading(_ action: FindBarAction) {
        switch action {
        case .cancel:
            readingGeneration += 1
            readingCursor = 0
            count = 0
            index = 0
            wrapped = false
            readingWeb?.evaluateJavaScript("xyzClearFind()") { _, _ in }
        case .focus:
            focusToken &+= 1
        case .useSelection:
            adoptSelection()
            visible = true
            scheduleRefresh()
        case .replaceOne, .replaceAll, .selectNextOccurrence:
            NSSound.beep()
        case .refresh:
            highlightReading(direction: 0)
        case .next:
            highlightReading(direction: 1)
        case .previous:
            highlightReading(direction: -1)
        }
    }

    /// `direction` 0 keeps the current hit. 1 and -1 move, wrapping with a cue.
    private func highlightReading(direction: Int) {
        guard let web = readingWeb else { return }
        let query = self.query
        if query.pattern.isEmpty {
            count = 0
            index = 0
            wrapped = false
            regexInvalid = false
            web.evaluateJavaScript("xyzClearFind()") { _, _ in }
            return
        }
        if direction == 0 {
            readingCursor = 0
        }
        readingGeneration += 1
        let token = readingGeneration
        let spec: [String: Any] = [
            "pattern": query.pattern,
            "matchCase": query.matchCase,
            "wholeWord": query.wholeWord,
            "regex": query.regex,
            "index": readingCursor,
            "direction": direction,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: spec),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("xyzHighlightFind(\(json))") { [weak self] value, _ in
            guard let self, token == self.readingGeneration else { return }
            let body = value as? [String: Any] ?? [:]
            let nextCount = Self.number(body["count"])
            let nextIndex = Self.number(body["index"])
            let didWrap = Self.flag(body["wrapped"])
            let invalid = Self.flag(body["invalid"])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { () -> Void in
                    guard token == self.readingGeneration else { return }
                    self.count = nextCount
                    self.index = nextIndex
                    self.wrapped = didWrap
                    self.regexInvalid = invalid
                    self.readingCursor = max(0, nextIndex - 1)
                }
            }
        }
    }

    /// Match counting waits so the bar can appear, and a new keystroke drops the previous pass.
    func scheduleRefresh() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            perform?(.refresh)
        }
    }

    func replacementText(for text: String, match: FindMatch) -> String {
        TextFind.replacement(in: text, match: match, query: query, with: replacement)
    }

    private static func number(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return 0
    }

    private static func flag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let flag = value as? Bool { return flag }
        return false
    }
}

/// Subscribes to the find model without rebuilding the editor. The bar overlays the text.
struct FindBarHost: View {
    @ObservedObject var model: EditorFindModel

    var body: some View {
        if model.visible {
            EditorFindBar(model: model)
        }
    }
}

struct EditorFindBar: View {
    @ObservedObject var model: EditorFindModel
    @FocusState private var slot: FindSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FindQueryField(
                    text: $model.pattern,
                    placeholder: String(localized: "Find"),
                    token: model.focusToken,
                    wantsFocus: slot == .query,
                    onSubmit: { shift in model.perform?(shift ? .previous : .next) },
                    onTab: { back in move(from: .query, back: back) },
                    onCancel: { model.dismiss() }
                )
                .frame(width: 160)
                toggle("Aa", help: "Match Case", slot: .matchCase, on: $model.matchCase)
                toggle("W", help: "Whole Word", slot: .word, on: $model.wholeWord)
                toggle(".*", help: "Regex", slot: .regex, on: $model.regex)
                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(model.regexInvalid ? Color.red.opacity(0.8) : Color.xyzSecondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 72, alignment: .trailing)
                stepButton("chevron.up", help: "Find Previous", action: .previous)
                stepButton("chevron.down", help: "Find Next", action: .next)
                Button { model.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.xyzSecondaryText)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Close"))
                .accessibilityLabel(String(localized: "Close"))
            }
            if model.showsReplace {
                HStack(spacing: 6) {
                    FindQueryField(
                        text: $model.replacement,
                        placeholder: String(localized: "Replace"),
                        token: 0,
                        wantsFocus: slot == .replace,
                        onSubmit: { _ in model.perform?(.replaceOne) },
                        onTab: { back in move(from: .replace, back: back) },
                        onCancel: { model.dismiss() }
                    )
                    .frame(width: 160)
                    Button("Replace") { model.perform?(.replaceOne) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(model.count == 0 ? Color.xyzSecondaryText : Color.xyzAccent)
                        .disabled(model.count == 0)
                    Button("Replace All") { model.perform?(.replaceAll) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(model.count == 0 ? Color.xyzSecondaryText : Color.xyzAccent)
                        .disabled(model.count == 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.editorBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.xyzDivider, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 14, y: 6)
        .onExitCommand { model.dismiss() }
        .onChange(of: model.pattern) { _, _ in
            model.wrapped = false
            model.scheduleRefresh()
        }
        .onChange(of: model.matchCase) { _, _ in model.scheduleRefresh() }
        .onChange(of: model.wholeWord) { _, _ in model.scheduleRefresh() }
        .onChange(of: model.regex) { _, _ in model.scheduleRefresh() }
        .onChange(of: model.focusToken) { _, _ in slot = .query }
    }

    private var countLabel: String {
        if model.pattern.isEmpty { return "" }
        if model.regexInvalid { return String(localized: "Invalid") }
        if model.count == 0 { return String(localized: "No results") }
        let base = String(format: String(localized: "%lld of %lld"), Int64(model.index), Int64(model.count))
        if model.wrapped { return base + " · " + String(localized: "Wrapped") }
        return base
    }

    private func stepButton(_ symbol: String, help: String, action: FindBarAction) -> some View {
        Button { model.perform?(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.xyzSecondaryText)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(String(localized: String.LocalizationValue(help)))
        .accessibilityLabel(String(localized: String.LocalizationValue(help)))
    }

    private func toggle(_ title: String, help: String, slot target: FindSlot, on: Binding<Bool>) -> some View {
        Button(title) { on.wrappedValue.toggle() }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(on.wrappedValue ? Color.xyzAccent : Color.xyzSecondaryText)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(on.wrappedValue ? Color.xyzSelection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .focused($slot, equals: target)
            .onKeyPress(.tab) {
                move(from: target, back: false)
                return .handled
            }
            .help(String(localized: String.LocalizationValue(help)))
            .accessibilityLabel(String(localized: String.LocalizationValue(help)))
            .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }

    private func move(from current: FindSlot, back: Bool) {
        let order: [FindSlot] = model.showsReplace
            ? [.query, .replace, .matchCase, .word, .regex]
            : [.query, .matchCase, .word, .regex]
        guard let index = order.firstIndex(of: current) else {
            slot = .query
            return
        }
        let next = back ? index - 1 : index + 1
        let wrapped = (next + order.count) % order.count
        slot = order[wrapped]
    }
}

private enum FindSlot: Hashable {
    case query
    case replace
    case matchCase
    case word
    case regex
}

/// The find field. Return finds the next match, Shift-Return the previous, Tab moves along the bar.
private struct FindQueryField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var token: Int
    var wantsFocus: Bool
    var onSubmit: (Bool) -> Void
    var onTab: (Bool) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .xyzInk
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        let editor = field.currentEditor() as? NSTextView
        if editor == nil, field.stringValue != text {
            field.stringValue = text
        }
        if token != 0, context.coordinator.token != token {
            context.coordinator.token = token
            context.coordinator.armed = true
            focus(field, selectAll: true)
        } else if wantsFocus, !context.coordinator.armed {
            context.coordinator.armed = true
            focus(field, selectAll: false)
        } else if !wantsFocus {
            context.coordinator.armed = false
        }
    }

    private func focus(_ field: NSTextField, selectAll: Bool) {
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            if selectAll {
                let length = (field.stringValue as NSString).length
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindQueryField
        var token = 0
        var armed = false

        init(_ parent: FindQueryField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            if parent.text != value { parent.text = value }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                parent.onSubmit(shift)
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.onTab(false)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                parent.onTab(true)
                return true
            }
            return false
        }
    }
}

/// Open files for the window. A preview tab is italic. A dirty file has a dot until the close button shows.
struct EditorTabBar: View {
    @ObservedObject var session: WorkspaceSession

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
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
                                closeOthers: {
                                    session.closeOtherTabs(keeping: tab.id)
                                },
                                closeRight: {
                                    session.closeTabs(toTheRightOf: tab.id)
                                },
                                closeAll: {
                                    session.closeAllTabs()
                                },
                                copyPath: {
                                    session.copyString(session.url(for: tab.id).path)
                                },
                                copyRelative: {
                                    session.copyRelativePath(of: tab.id)
                                },
                                reveal: {
                                    session.revealTabInFinder(tab.id)
                                },
                                move: {
                                    session.onMoveTab?(tab.id)
                                }
                            )
                            .id(tab.id)
                        }
                    }
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
        .frame(height: 35)
        .background(Color.editorBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.xyzDivider).frame(height: 1)
        }
        .background(ScrollElasticityNone())
    }
}

private struct EditorTabItem: View {
    var tab: EditorTab
    var active: Bool
    var select: () -> Void
    var close: () -> Void
    var closeOthers: () -> Void
    var closeRight: () -> Void
    var closeAll: () -> Void
    var copyPath: () -> Void
    var copyRelative: () -> Void
    var reveal: () -> Void
    var move: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            Button(action: select) {
                Text(name)
                    .font(titleFont)
                    .foregroundStyle(active ? Color.xyzInk : Color.xyzSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            closeControl
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 120, maxWidth: 200)
        .frame(maxHeight: .infinity)
        .background(active ? Color.editorBackground : Color.clear)
        .overlay(alignment: .top) {
            if active {
                Rectangle()
                    .fill(Color.xyzAccent)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.xyzDivider).frame(width: 1)
        }
        .onHover { hovering = $0 }
        .overlay(TabMiddleClick(tabID: tab.id, action: close))
        .help(tab.id)
        .contextMenu {
            Button("Close") { close() }
            Button("Close Others") { closeOthers() }
            Button("Close to the Right") { closeRight() }
            Button("Close All") { closeAll() }
            Divider()
            Button("Copy Path") { copyPath() }
            Button("Copy Relative Path") { copyRelative() }
            Button("Reveal in Finder") { reveal() }
            Divider()
            Button("Move to New Window") { move() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 28).onEnded { value in
                if abs(value.translation.height) > 48 {
                    move()
                }
            }
        )
    }

    private var showsClose: Bool { active || hovering }

    @ViewBuilder
    private var closeControl: some View {
        if showsClose {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Close Tab"))
        } else {
            Circle()
                .fill(tab.isDirty ? Color.xyzInk.opacity(0.72) : Color.clear)
                .frame(width: 7, height: 7)
                .frame(width: 16, height: 16)
                .accessibilityLabel(tab.isDirty ? String(localized: "Unsaved") : "")
                .accessibilityHidden(!tab.isDirty)
        }
    }

    private var name: String {
        (tab.id as NSString).lastPathComponent
    }

    private var iconName: String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "doc.text"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "swift", "js", "ts", "py", "rb", "go", "rs", "c", "h", "m", "cpp":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private var titleFont: Font {
        if tab.isPreview {
            return Font.system(size: 12).italic()
        }
        return Font.system(size: 12, weight: active ? .semibold : .regular)
    }
}

/// Middle-click closes a tab. A monitor looks at the tab's frame, because the title field eats the event before hit testing.
private struct TabMiddleClick: NSViewRepresentable {
    var tabID: String
    var action: () -> Void

    func makeNSView(context: Context) -> TabMiddleTarget {
        let view = TabMiddleTarget()
        view.tabID = tabID
        view.action = action
        return view
    }

    func updateNSView(_ view: TabMiddleTarget, context: Context) {
        view.tabID = tabID
        view.action = action
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TabMiddleTarget, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: proposal.height ?? 35)
    }
}

private final class TabMiddleTarget: NSView {
    var tabID = ""
    var action: () -> Void = {}
    private static var live: [WeakTab] = []
    private static var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.live.removeAll { $0.view == nil }
        if window != nil {
            Self.live.append(WeakTab(view: self))
            Self.install()
        }
    }

    private static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { event in
            guard event.buttonNumber == 2, event.window != nil else { return event }
            live.removeAll { $0.view == nil }
            for item in live {
                guard let view = item.view, view.window === event.window else { continue }
                let local = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(local) else { continue }
                view.action()
                return nil
            }
            return event
        }
    }
}

private struct WeakTab {
    weak var view: TabMiddleTarget?
}

/// The file's path, from the folder root. Choosing a folder reveals it in the sidebar.
struct EditorBreadcrumb: View {
    var rootName: String
    var relativePath: String
    var siblings: (String) -> [WorkspaceNode] = { _ in [] }
    var choose: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                let crumbs = WorkspacePaths.crumbs(rootName: rootName, relativePath: relativePath)
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Text("›")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    crumbMenu(crumb, emphasized: index == crumbs.count - 1)
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(height: 22)
        .background(Color.editorBackground)
        .background(ScrollElasticityNone())
    }

    private func crumbMenu(_ crumb: WorkspaceCrumb, emphasized: Bool) -> some View {
        let nodes = siblings(crumb.relativePath)
        return Menu {
            if nodes.isEmpty {
                Button(String(localized: "Nothing else here")) {}
                    .disabled(true)
            } else {
                ForEach(nodes, id: \.relativePath) { node in
                    Button {
                        choose(node.relativePath)
                    } label: {
                        Text(node.name)
                    }
                }
            }
        } label: {
            Text(crumb.name)
                .font(.system(size: 12, weight: emphasized ? .medium : .regular))
                .foregroundStyle(emphasized ? Color.xyzInk : Color.xyzSecondaryText)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
    var showsWrap = false
    var onEncoding: ((TextEncoding) -> Void)?
    var onLineEnding: ((LineEnding) -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            if let caret {
                Button {
                    EditorCommands.shared.goToLine(nil)
                } label: {
                    statusText(position(caret))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Go to Line"))
                if let selection = selection(caret) {
                    separator
                    statusText(selection)
                }
            }
            Spacer(minLength: 8)
            if showsWrap {
                statusText(String(localized: "Wrap"))
                separator
            }
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
        .background(Color.sidebarBackground)
        .overlay(StatusBarMarker())
        .overlay(alignment: .top) {
            Rectangle().fill(Color.xyzDivider).frame(height: 1)
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
            .foregroundStyle(Color.xyzSecondaryText)
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

/// Markdown headings for the right sidebar. A chevron collapses the levels under it.
struct OutlinePane: View {
    var entries: [OutlineEntry]
    var currentLine: Int = 0
    var choose: (Int) -> Void
    @State private var collapsed: Set<String> = []

    private var activeID: String? {
        guard currentLine > 0 else { return nil }
        return entries.last(where: { $0.line <= currentLine })?.id
    }

    private var visibleEntries: [OutlineEntry] {
        var hiddenBelow: Int?
        var shown: [OutlineEntry] = []
        for entry in entries {
            if let limit = hiddenBelow {
                if entry.depth > limit { continue }
                hiddenBelow = nil
            }
            shown.append(entry)
            if collapsed.contains(entry.id) {
                hiddenBelow = entry.depth
            }
        }
        return shown
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                Text(String(localized: "No Outline"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleEntries) { entry in
                                let active = entry.id == activeID
                                let children = hasChildren(entry)
                                HStack(spacing: 2) {
                                    if children {
                                        Button {
                                            if collapsed.contains(entry.id) {
                                                collapsed.remove(entry.id)
                                            } else {
                                                collapsed.insert(entry.id)
                                            }
                                        } label: {
                                            Image(systemName: collapsed.contains(entry.id) ? "chevron.right" : "chevron.down")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 14, height: 22)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        Color.clear.frame(width: 14, height: 22)
                                    }
                                    Button {
                                        choose(entry.line)
                                    } label: {
                                        Text(entry.title)
                                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                                            .foregroundStyle(Color.xyzInk)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.leading, 8 + CGFloat(min(entry.depth, 6)) * 12)
                                .padding(.trailing, 8)
                                .background(active ? Color.xyzSelection : Color.clear)
                                .id(entry.id)
                                .help(String(format: String(localized: "Ln %lld, Col %lld"), Int64(entry.line), Int64(1)))
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .background(ScrollElasticityNone())
                    .onChange(of: activeID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sidebarBackground)
    }

    private func hasChildren(_ entry: OutlineEntry) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        let next = entries.index(after: index)
        guard next < entries.endIndex else { return false }
        return entries[next].depth > entry.depth
    }
}

/// Right sidebar for a Markdown note. Same tint as the file tree.
struct OutlineSidebar: View {
    @ObservedObject var session: WorkspaceSession
    @ObservedObject var outline: OutlineModel

    var body: some View {
        VStack(spacing: 0) {
            Text(String(localized: "Outline").localizedUppercase)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .accessibilityLabel(String(localized: "Outline"))
            OutlinePane(entries: outline.entries, currentLine: followedLine) { line in
                session.scrollLink.revealLine(line)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sidebarBackground)
    }

    /// Reading follows the line on screen. Editing follows the caret.
    private var followedLine: Int {
        FileOutline.followedLine(
            reading: session.viewMode == .reading,
            viewportLine: session.viewportLine,
            caretLine: session.caret.line
        )
    }
}

/// Marks the status bar so the editor pane can stop at its top.
private struct StatusBarMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        StatusBarMarkerView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier("xyz.statusBar")
    }
}

/// Fills the status-bar overlay so the editor can measure its real frame.
private final class StatusBarMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        identifier = NSUserInterfaceItemIdentifier("xyz.statusBar")
    }
}

/// Values the status bar draws. The bar itself spans the window, under the sidebar and the editor.
struct EditorStatusSnapshot: Equatable {
    var visible = false
    var caret: EditorCaret?
    var encoding: TextEncoding?
    var lineEnding: LineEnding?
    var mixedEndings = false
    var typeName = ""
    var words: TextStatistics?
    var showsReadingTime = false
    var detail: String?
    var canEditEncoding = false
    var canEditEnding = false

    static let empty = EditorStatusSnapshot()
}

struct EditorStatusKey: PreferenceKey {
    static var defaultValue = EditorStatusSnapshot.empty
    static func reduce(value: inout EditorStatusSnapshot, nextValue: () -> EditorStatusSnapshot) {
        value = nextValue()
    }
}

@MainActor
final class OutlineModel: ObservableObject {
    @Published private(set) var entries: [OutlineEntry] = []
    private var task: Task<Void, Never>?

    func clear() {
        task?.cancel()
        entries = []
    }

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
                    .background(offset == index ? Color.xyzSelection : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 420)
        .padding(.vertical, 6)
        .background(Color.editorBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.xyzDivider, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
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
