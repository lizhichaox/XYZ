#if os(macOS)
import AppKit
import AVKit
import PDFKit
#if canImport(QuickLookUI)
import QuickLookUI
#else
import Quartz
#endif
import SwiftUI
import XYZCore

/// Image, PDF, audio, video, or Quick Look. The text editor is not used.
struct FileSurface: View {
    var url: URL
    var viewer: FileViewerKind?
    var onDetail: (String?) -> Void = { _ in }

    var body: some View {
        Group {
            switch viewer {
            case .image:
                ImageSurface(url: url, onDetail: onDetail)
            case .pdf:
                PDFSurface(url: url, onDetail: onDetail)
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
    var onDetail: (String?) -> Void

    func makeNSView(context: Context) -> FitImageView {
        let view = FitImageView()
        view.onDetail = { [weak view] text in
            let shown = view?.url
            DispatchQueue.main.async {
                guard view?.url == shown else { return }
                onDetail(text)
            }
        }
        view.show(url)
        return view
    }

    func updateNSView(_ view: FitImageView, context: Context) {
        view.onDetail = { [weak view] text in
            let shown = view?.url
            DispatchQueue.main.async {
                guard view?.url == shown else { return }
                onDetail(text)
            }
        }
        if view.url != url {
            view.show(url)
        }
    }
}

private final class FitImageView: NSView {
    var url: URL?
    var onDetail: ((String?) -> Void)?
    private var image: NSImage?
    /// `fitting` scales the picture into the pane. Otherwise `magnification` is 1 at the image's own size.
    private var fitting = true
    private var magnification: CGFloat = 1

    override var isOpaque: Bool { true }

    func show(_ url: URL) {
        self.url = url
        image = NSImage(contentsOf: url)
        fitting = true
        magnification = 1
        needsDisplay = true
        report()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = fitting ? fitScale(for: image) : magnification
        let width = image.size.width * scale
        let height = image.size.height * scale
        let rect = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: [
            .interpolation: NSImageInterpolation.high,
        ])
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        fitting.toggle()
        if !fitting {
            magnification = 1
        }
        needsDisplay = true
        report()
    }

    override func magnify(with event: NSEvent) {
        guard let image else { return }
        if fitting {
            fitting = false
            magnification = fitScale(for: image)
        }
        let next = magnification * (1 + event.magnification)
        magnification = min(16, max(0.05, next))
        needsDisplay = true
        report()
    }

    private func fitScale(for image: NSImage) -> CGFloat {
        let canvas = bounds.insetBy(dx: 24, dy: 24)
        guard canvas.width > 1, canvas.height > 1, image.size.width > 0, image.size.height > 0 else { return 1 }
        return min(canvas.width / image.size.width, canvas.height / image.size.height)
    }

    private func report() {
        guard let image else {
            onDetail?(nil)
            return
        }
        let pixels = pixelSize(of: image)
        let mode = fitting ? String(localized: "Fit") : "\(Int((magnification * 100).rounded()))%"
        onDetail?("\(pixels.0) × \(pixels.1) · \(mode)")
    }

    private func pixelSize(of image: NSImage) -> (Int, Int) {
        if let rep = image.representations.first(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }) {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return (max(1, Int(image.size.width.rounded())), max(1, Int(image.size.height.rounded())))
    }
}

private struct PDFSurface: NSViewRepresentable {
    var url: URL
    var onDetail: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.backgroundColor = .textBackgroundColor
        context.coordinator.onDetail = onDetail
        context.coordinator.bind(view)
        view.document = PDFDocument(url: url)
        ScrollElasticityNone.silence(view)
        context.coordinator.report()
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onDetail = onDetail
        context.coordinator.bind(view)
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            context.coordinator.report()
        }
        ScrollElasticityNone.silence(view)
    }

    final class Coordinator: NSObject {
        var onDetail: (String?) -> Void = { _ in }
        private weak var view: PDFView?

        func bind(_ view: PDFView) {
            guard self.view !== view else { return }
            if let old = self.view {
                NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: old)
            }
            self.view = view
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
        }

        @objc func pageChanged(_ notification: Notification) {
            report()
        }

        func report() {
            guard let view, let document = view.document else { return }
            let count = document.pageCount
            let index: Int
            if let page = view.currentPage {
                index = document.index(for: page) + 1
            } else {
                index = count > 0 ? 1 : 0
            }
            let text = String(format: String(localized: "Page %lld of %lld"), Int64(max(index, 1)), Int64(max(count, 1)))
            let send = onDetail
            let shown = document.documentURL
            DispatchQueue.main.async { [weak view] in
                guard view?.document?.documentURL == shown else { return }
                send(text)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
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
        guard let preview else {
            installUnavailable()
            return
        }
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

    private func installUnavailable() {
        let label = NSTextField(wrappingLabelWithString: String(localized: "XYZ can't preview this file."))
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
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
