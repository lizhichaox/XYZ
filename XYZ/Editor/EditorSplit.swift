#if os(macOS)
import AppKit
import SwiftUI
import XYZCore

/// Editor and preview panes. Both stay mounted so the web view is not recreated.
///
/// Changing mode moves the divider. It does not change the window frame.
struct EditorPreviewSplit<Editor: View, Preview: View>: View {
    var mode: EditorViewMode
    /// Changes when the open file changes. The divider does not animate for that.
    var fileID: String = ""
    var editor: Editor
    var preview: Preview

    var body: some View {
        EditorPreviewSplitRepresentable(
            mode: mode,
            fileID: fileID,
            editor: AnyView(editor),
            preview: AnyView(preview)
        )
    }
}

private struct EditorPreviewSplitRepresentable: NSViewRepresentable {
    var mode: EditorViewMode
    var fileID: String
    var editor: AnyView
    var preview: AnyView

    func makeNSView(context: Context) -> EditorPreviewSplitContainer {
        let view = EditorPreviewSplitContainer()
        view.editorHost.rootView = editor
        view.previewHost.rootView = preview
        view.setMode(mode, fileID: fileID)
        return view
    }

    func updateNSView(_ view: EditorPreviewSplitContainer, context: Context) {
        view.editorHost.rootView = editor
        view.previewHost.rootView = preview
        view.setMode(mode, fileID: fileID)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: EditorPreviewSplitContainer,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 600)
    }
}

final class EditorPreviewSplitContainer: NSView, NSSplitViewDelegate {
    static let fractionKey = "xyz.editorPreviewFraction"

    let split = HairlineSplitView()
    let editorHost = FixedHostingView(rootView: AnyView(EmptyView()))
    let previewHost = FixedHostingView(rootView: AnyView(EmptyView()))

    private var mode: EditorViewMode = .preview
    private var fileID = ""
    private var didApplyInitial = false
    private var applyingPosition = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        configure(editorHost)
        configure(previewHost)
        editorHost.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
        previewHost.frame = NSRect(x: 0, y: 0, width: 480, height: 640)
        split.addArrangedSubview(editorHost)
        split.addArrangedSubview(previewHost)
        let priority = NSLayoutConstraint.Priority(249)
        split.setHoldingPriority(priority, forSubviewAt: 0)
        split.setHoldingPriority(priority, forSubviewAt: 1)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func setMode(_ mode: EditorViewMode, fileID: String) {
        let fileChanged = fileID != self.fileID
        self.fileID = fileID
        let changed = self.mode != mode
        self.mode = mode
        split.showsDivider = mode == .preview
        guard bounds.width > 1, split.arrangedSubviews.count == 2 else {
            if mode == .preview { didApplyInitial = false }
            return
        }
        if mode == .preview { didApplyInitial = true }
        let target = position(for: mode, width: bounds.width)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animate = changed && !fileChanged && !reduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? 0.22 : 0
            context.allowsImplicitAnimation = animate
            split.animator().setPosition(target, ofDividerAt: 0)
        }
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        guard bounds.width > 1, split.arrangedSubviews.count == 2 else { return }
        if mode != .preview {
            let target = position(for: mode, width: bounds.width)
            if abs(split.arrangedSubviews[0].frame.width - target) > 1 {
                applyingPosition = true
                split.setPosition(target, ofDividerAt: 0)
                applyingPosition = false
            }
            return
        }
        guard !didApplyInitial else { return }
        didApplyInitial = true
        applyingPosition = true
        split.setPosition(position(for: .preview, width: bounds.width), ofDividerAt: 0)
        applyingPosition = false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingPosition, didApplyInitial, mode == .preview, bounds.width > 1 else { return }
        guard split.arrangedSubviews.count == 2 else { return }
        let fraction = Double(split.arrangedSubviews[0].frame.width / bounds.width)
        guard fraction > 0.15, fraction < 0.85 else { return }
        UserDefaults.standard.set(fraction, forKey: Self.fractionKey)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if mode != .preview { return 0 }
        return min(260, splitView.bounds.width / 2)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        if mode != .preview { return splitView.bounds.width }
        let minPane = min(260, splitView.bounds.width / 2)
        return max(minPane, splitView.bounds.width - minPane)
    }

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        mode == .preview ? proposedEffectiveRect : .zero
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    private func position(for mode: EditorViewMode, width: CGFloat) -> CGFloat {
        switch mode {
        case .coding:
            return width
        case .reading:
            return 0
        case .preview:
            let stored = UserDefaults.standard.double(forKey: Self.fractionKey)
            let fraction = (stored > 0.2 && stored < 0.8) ? stored : 0.5
            let minPane = min(260, width / 2)
            return min(max(width * CGFloat(fraction), minPane), width - minPane)
        }
    }

    private func configure(_ host: FixedHostingView) {
        host.sizingOptions = []
        host.setContentHuggingPriority(.init(1), for: .horizontal)
        host.setContentHuggingPriority(.init(1), for: .vertical)
        host.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        host.setContentCompressionResistancePriority(.init(1), for: .vertical)
    }
}

/// Keeps SwiftUI from reporting the text view's line width as the pane's size.
final class FixedHostingView: NSHostingView<AnyView> {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

final class HairlineSplitView: NSSplitView {
    var showsDivider = true

    override var dividerThickness: CGFloat { showsDivider ? 8 : 0 }

    override func drawDivider(in rect: NSRect) {
        guard showsDivider else { return }
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        let line = NSRect(x: floor(rect.midX), y: rect.minY, width: 1, height: rect.height)
        NSColor.separatorColor.setFill()
        line.fill()
    }
}
#endif
