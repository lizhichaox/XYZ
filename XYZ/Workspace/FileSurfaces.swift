#if os(macOS)
import AppKit
import AVKit
import PDFKit
import Quartz
import SwiftUI
import XYZCore

/// Image, PDF, audio, video, or Quick Look. The text editor is not used.
struct FileSurface: View {
    var url: URL
    var viewer: FileViewerKind?

    var body: some View {
        Group {
            switch viewer {
            case .image:
                ImageSurface(url: url)
            case .pdf:
                PDFSurface(url: url)
            case .audiovisual:
                MediaSurface(url: url)
            case nil:
                QuickLookSurface(url: url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pretty JSON. The source line that was on screen is restored when Reading closes.
struct JSONReadingView: View {
    var text: String
    var scrollLink: EditorScrollLink
    @AppStorage(XYZEditorStyle.fontSizeKey) private var fontSize = XYZEditorStyle.defaultFontSize
    @AppStorage(XYZEditorStyle.readableWidthKey) private var readableWidth = false

    var body: some View {
        let pretty = JSONText.pretty(text)
        GeometryReader { geo in
            let style = XYZEditorStyle(
                fontSize: CGFloat(XYZEditorStyle.clampedFontSize(fontSize)),
                readableWidth: readableWidth
            )
            let inset = style.sideInset(for: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if pretty == nil {
                        Text("This JSON couldn't be formatted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(pretty ?? text)
                        .font(.system(size: style.fontSize, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, inset)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(ScrollElasticityNone())
        }
        .background(Color.editorBackground)
        .modifier(ReadingAnchorHold(scrollLink: scrollLink))
    }
}

/// A table for CSV and TSV. Wide rows scroll sideways inside the page.
struct CSVReadingView: View {
    var text: String
    var scrollLink: EditorScrollLink
    @AppStorage(XYZEditorStyle.readableWidthKey) private var readableWidth = false
    @AppStorage(XYZEditorStyle.fontSizeKey) private var fontSize = XYZEditorStyle.defaultFontSize

    var body: some View {
        let grid = CSVText.parse(text)
        GeometryReader { geo in
            let style = XYZEditorStyle(
                fontSize: CGFloat(XYZEditorStyle.clampedFontSize(fontSize)),
                readableWidth: readableWidth
            )
            let inset = style.sideInset(for: geo.size.width)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(grid.rows.enumerated()), id: \.offset) { index, row in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 13, weight: index == 0 ? .semibold : .regular))
                                    .foregroundStyle(index == 0 ? Color.secondary : Color.primary)
                                    .lineLimit(1)
                                    .padding(.vertical, 5)
                                    .frame(minWidth: 72, alignment: .leading)
                            }
                        }
                        Divider().opacity(0.35)
                    }
                }
                    if grid.truncated {
                        Text(String(format: String(localized: "Showing the first %lld rows."), Int64(grid.rows.count)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(ScrollElasticityNone())
        }
        .background(Color.editorBackground)
        .modifier(ReadingAnchorHold(scrollLink: scrollLink))
    }
}

/// Keeps the source line that was at the top, so leaving Reading does not jump.
private struct ReadingAnchorHold: ViewModifier {
    var scrollLink: EditorScrollLink

    func body(content: Content) -> some View {
        content.onAppear {
            let anchor = scrollLink.take(for: .reading)
            scrollLink.capture = {
                anchor ?? EditorScrollAnchor(fraction: 0, probe: "", line: 1)
            }
        }
    }
}

private struct ImageSurface: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> FitImageView {
        let view = FitImageView()
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ view: FitImageView, context: Context) {
        if view.url != url {
            view.url = url
            view.image = NSImage(contentsOf: url)
        }
    }
}

private final class FitImageView: NSView {
    var url: URL?
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let canvas = bounds.insetBy(dx: 24, dy: 24)
        guard canvas.width > 1, canvas.height > 1 else { return }
        let scale = min(canvas.width / image.size.width, canvas.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        let rect = NSRect(
            x: canvas.midX - width / 2,
            y: canvas.midY - height / 2,
            width: width,
            height: height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [
            .interpolation: NSImageInterpolation.high,
        ])
    }
}

private struct PDFSurface: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.backgroundColor = .textBackgroundColor
        view.document = PDFDocument(url: url)
        ScrollElasticityNone.silence(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        ScrollElasticityNone.silence(view)
    }
}

private struct MediaSurface: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .minimal
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let current = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        guard current != url else { return }
        view.player?.pause()
        view.player = AVPlayer(url: url)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

private struct QuickLookSurface: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> QuickLookHost {
        let host = QuickLookHost()
        host.show(url)
        return host
    }

    func updateNSView(_ host: QuickLookHost, context: Context) {
        host.show(url)
    }
}

private final class QuickLookHost: NSView {
    private let preview: QLPreviewView?

    override init(frame frameRect: NSRect) {
        preview = QLPreviewView(frame: frameRect, style: .compact)
        super.init(frame: frameRect)
        guard let preview else { return }
        preview.autostarts = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(_ url: URL) {
        guard (preview?.previewItem as? NSURL)?.path != url.path else { return }
        preview?.previewItem = url as NSURL
        preview?.refreshPreviewItem()
    }
}

extension ScrollElasticityNone {
    static func silence(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
        }
        for subview in view.subviews {
            silence(subview)
        }
    }
}
#endif
