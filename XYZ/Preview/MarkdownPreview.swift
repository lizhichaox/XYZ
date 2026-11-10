import SwiftUI
import XYZCore

/// Latest editor text, without publishing on each keystroke.
///
/// The preview view attaches while it is on screen. The editor calls `send` for every
/// change; the preview debounces rendering. `attach` / `detach` are keyed so a preview
/// that is leaving cannot clear a preview that just appeared.
@MainActor
final class PreviewBridge {
    private(set) var latestText: String
    private var listenerID: ObjectIdentifier?
    private var onText: ((String) -> Void)?

    init(text: String) {
        latestText = text
    }

    func send(_ text: String) {
        latestText = text
        onText?(text)
    }

    func attach(id: ObjectIdentifier, handler: @escaping (String) -> Void) {
        listenerID = id
        onText = handler
    }

    func detach(id: ObjectIdentifier) {
        guard listenerID == id else { return }
        listenerID = nil
        onText = nil
    }
}

@MainActor
final class PreviewModel: ObservableObject {
    @Published private(set) var html: String = ""

    /// Below this size, rendering stays on the main actor. Larger documents render off it.
    private static let synchronousLimit = 20_000

    /// Reading does not request a picture from another server unless this is on.
    private var allowsRemoteImages = false
    /// Task checkboxes are interactive only when the note can be edited.
    private var allowsTaskToggle = true

    private var task: Task<Void, Never>?
    private var generation = 0

    /// The setting changed. The next `schedule` renders with the new value.
    func setAllowsRemoteImages(_ allows: Bool) {
        allowsRemoteImages = allows
    }

    func setAllowsTaskToggle(_ allows: Bool) {
        allowsTaskToggle = allows
    }

    func schedule(_ text: String, immediate: Bool) {
        task?.cancel()
        generation &+= 1
        let token = generation
        let allowsRemoteImages = allowsRemoteImages
        let allowsTaskToggle = allowsTaskToggle
        if immediate && text.utf8.count <= Self.synchronousLimit {
            publish(MarkdownHTML.render(
                text,
                allowRemoteImages: allowsRemoteImages,
                allowsTaskToggle: allowsTaskToggle
            ))
            return
        }
        task = Task { [weak self] in
            if !immediate {
                let wait = text.utf8.count > 120_000 ? 420 : 220
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            let rendered = await Self.render(
                text,
                allowRemoteImages: allowsRemoteImages,
                allowsTaskToggle: allowsTaskToggle
            )
            guard self.generation == token else { return }
            self.publish(rendered)
        }
    }

    private static func render(
        _ text: String,
        allowRemoteImages: Bool,
        allowsTaskToggle: Bool
    ) async -> String {
        if text.utf8.count <= synchronousLimit {
            return MarkdownHTML.render(
                text,
                allowRemoteImages: allowRemoteImages,
                allowsTaskToggle: allowsTaskToggle
            )
        }
        return await Task.detached(priority: .userInitiated) {
            MarkdownHTML.render(
                text,
                allowRemoteImages: allowRemoteImages,
                allowsTaskToggle: allowsTaskToggle
            )
        }.value
    }

    private func publish(_ rendered: String) {
        guard html != rendered else { return }
        html = rendered
    }

    /// First paint. Called before the web view exists so the shell can include the HTML.
    func adopt(_ text: String) {
        guard text.utf8.count <= Self.synchronousLimit else { return }
        publish(MarkdownHTML.render(
            text,
            allowRemoteImages: allowsRemoteImages,
            allowsTaskToggle: allowsTaskToggle
        ))
    }
}

struct MarkdownPreview: View {
    var bridge: PreviewBridge
    var host: PreviewWebHost
    var scrollLink: EditorScrollLink
    /// The note's folder, for relative pictures and links.
    var baseDirectory: URL?
    /// Off unless the Reading setting turns remote pictures on.
    var allowsRemoteImages: Bool = false
    /// Task checkboxes are interactive only when the note can be edited.
    var allowsTaskToggle: Bool = false
    /// A task checkbox in Reading was clicked. The argument is the source line.
    var toggleTask: ((Int) -> Void)?
    /// A tag chip in Reading was clicked. The argument is the tag without its leading `#`.
    var openTag: ((String) -> Void)?
    @StateObject private var model: PreviewModel

    init(
        bridge: PreviewBridge,
        host: PreviewWebHost,
        scrollLink: EditorScrollLink,
        baseDirectory: URL? = nil,
        allowsRemoteImages: Bool = false,
        allowsTaskToggle: Bool = false,
        toggleTask: ((Int) -> Void)? = nil,
        openTag: ((String) -> Void)? = nil
    ) {
        self.bridge = bridge
        self.host = host
        self.scrollLink = scrollLink
        self.baseDirectory = baseDirectory
        self.allowsRemoteImages = allowsRemoteImages
        self.allowsTaskToggle = allowsTaskToggle
        self.toggleTask = toggleTask
        self.openTag = openTag
        let model = PreviewModel()
        model.setAllowsRemoteImages(allowsRemoteImages)
        model.setAllowsTaskToggle(allowsTaskToggle)
        model.adopt(bridge.latestText)
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        MarkdownWebView(
            html: model.html,
            baseDirectory: baseDirectory,
            host: host,
            scrollLink: scrollLink,
            toggleTask: toggleTask,
            openTag: openTag
        )
            .background(Color.editorBackground)
            .accessibilityLabel("Markdown preview")
            .onAppear {
                let previewModel = model
                bridge.attach(id: ObjectIdentifier(previewModel)) { [weak previewModel] text in
                    previewModel?.schedule(text, immediate: false)
                }
                previewModel.schedule(bridge.latestText, immediate: true)
            }
            .onChange(of: allowsRemoteImages) { _, value in
                model.setAllowsRemoteImages(value)
                model.schedule(bridge.latestText, immediate: true)
            }
            .onChange(of: allowsTaskToggle) { _, value in
                model.setAllowsTaskToggle(value)
                model.schedule(bridge.latestText, immediate: true)
            }
            .onDisappear {
                bridge.detach(id: ObjectIdentifier(model))
            }
    }
}
