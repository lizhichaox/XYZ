#if os(macOS)
import AppKit
import SwiftUI

/// Side-by-side editor and preview.
///
/// SwiftUI's `HSplitView` sizes itself from the text view's fitting width, which
/// collapses the editor to a narrow column and leaves the preview blank. This
/// split view owns both widths, starts at half, and keeps a draggable hairline.
struct EditorPreviewSplit<Editor: View, Preview: View>: View {
    var showsPreview: Bool
    var editor: Editor
    var preview: Preview

    var body: some View {
        EditorPreviewSplitRepresentable(
            showsPreview: showsPreview,
            editor: AnyView(editor),
            preview: AnyView(preview)
        )
    }
}

private struct EditorPreviewSplitRepresentable: NSViewRepresentable {
    var showsPreview: Bool
    var editor: AnyView
    var preview: AnyView

    func makeNSView(context: Context) -> EditorPreviewSplitContainer {
        let view = EditorPreviewSplitContainer()
        view.editorHost.rootView = editor
        view.previewHost.rootView = preview
        view.setShowsPreview(showsPreview)
        return view
    }

    func updateNSView(_ view: EditorPreviewSplitContainer, context: Context) {
        view.editorHost.rootView = editor
        view.previewHost.rootView = preview
        view.setShowsPreview(showsPreview)
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

    private var showsPreview = false
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

    func setShowsPreview(_ show: Bool) {
        let expected = show ? 2 : 1
        guard show != showsPreview || split.arrangedSubviews.count != expected else { return }
        showsPreview = show
        if show {
            if !split.arrangedSubviews.contains(previewHost) {
                split.addArrangedSubview(previewHost)
                let priority = NSLayoutConstraint.Priority(249)
                split.setHoldingPriority(priority, forSubviewAt: 0)
                split.setHoldingPriority(priority, forSubviewAt: 1)
                didApplyInitial = false
            }
        } else if split.arrangedSubviews.contains(previewHost) {
            previewHost.removeFromSuperview()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        guard showsPreview, !didApplyInitial, bounds.width > 80, split.arrangedSubviews.count == 2 else { return }
        didApplyInitial = true
        let stored = UserDefaults.standard.double(forKey: Self.fractionKey)
        let fraction = (stored > 0.2 && stored < 0.8) ? stored : 0.5
        let minPane = min(260, bounds.width / 2)
        let position = min(max(bounds.width * CGFloat(fraction), minPane), bounds.width - minPane)
        applyingPosition = true
        split.setPosition(position, ofDividerAt: 0)
        applyingPosition = false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingPosition, didApplyInitial, showsPreview, bounds.width > 1 else { return }
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
        min(260, splitView.bounds.width / 2)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let minPane = min(260, splitView.bounds.width / 2)
        return max(minPane, splitView.bounds.width - minPane)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
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
    override var dividerThickness: CGFloat { 8 }

    override func drawDivider(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        let line = NSRect(x: floor(rect.midX), y: rect.minY, width: 1, height: rect.height)
        NSColor.separatorColor.setFill()
        line.fill()
    }
}
#endif
