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

    private var task: Task<Void, Never>?
    private var generation = 0

    func schedule(_ text: String, immediate: Bool) {
        task?.cancel()
        generation &+= 1
        let token = generation
        if immediate && text.utf8.count <= Self.synchronousLimit {
            publish(MarkdownHTML.render(text))
            return
        }
        task = Task { [weak self] in
            if !immediate {
                let wait = text.utf8.count > 120_000 ? 420 : 220
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            let rendered = await Self.render(text)
            guard self.generation == token else { return }
            self.publish(rendered)
        }
    }

    private static func render(_ text: String) async -> String {
        if text.utf8.count <= synchronousLimit {
            return MarkdownHTML.render(text)
        }
        return await Task.detached(priority: .userInitiated) {
            MarkdownHTML.render(text)
        }.value
    }

    private func publish(_ rendered: String) {
        guard html != rendered else { return }
        html = rendered
    }

    /// First paint. Called before the web view exists so the shell can include the HTML.
    func adopt(_ text: String) {
        guard text.utf8.count <= Self.synchronousLimit else { return }
        publish(MarkdownHTML.render(text))
    }
}

struct MarkdownPreview: View {
    var bridge: PreviewBridge
    var host: PreviewWebHost
    var scrollLink: EditorScrollLink
    @StateObject private var model: PreviewModel

    init(bridge: PreviewBridge, host: PreviewWebHost, scrollLink: EditorScrollLink) {
        self.bridge = bridge
        self.host = host
        self.scrollLink = scrollLink
        let model = PreviewModel()
        model.adopt(bridge.latestText)
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        MarkdownWebView(html: model.html, host: host, scrollLink: scrollLink)
            .background(Color.editorBackground)
            .accessibilityLabel("Markdown preview")
            .onAppear {
                let previewModel = model
                bridge.attach(id: ObjectIdentifier(previewModel)) { [weak previewModel] text in
                    previewModel?.schedule(text, immediate: false)
                }
                previewModel.schedule(bridge.latestText, immediate: true)
            }
            .onDisappear {
                bridge.detach(id: ObjectIdentifier(model))
            }
    }
}
