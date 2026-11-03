#if os(macOS)
import AppKit
import os

/// Opt-in trace for the gutter, ⌘K, and stray windows.
///
/// Turn it on with `defaults write com.lizhichao.XYZ XYZDiagnostics -bool YES` and relaunch,
/// or pass `-XYZDiagnostics`. Lines go to the unified log (subsystem `com.lizhichao.XYZ`,
/// category `diag`) and to `xyz-diag.log` in `FileManager.temporaryDirectory`. For this
/// sandboxed app that directory is
/// `~/Library/Containers/com.lizhichao.XYZ/Data/tmp/`.
enum XYZDiagnostics {
    static let argument = "-XYZDiagnostics"
    static let defaultsKey = "XYZDiagnostics"

    private static let log = Logger(subsystem: "com.lizhichao.XYZ", category: "diag")
    private static var decided = false
    private static var on = false
    private static var drawLogs = 0

    static var enabled: Bool {
        if decided { return on }
        decided = true
        on = ProcessInfo.processInfo.arguments.contains(argument)
            || UserDefaults.standard.bool(forKey: defaultsKey)
        return on
    }

    static func start() {
        guard enabled else { return }
        let path = fileURL().path
        note("diagnostics on")
        note("log file \(path)")
        dump(reason: "launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            dump(reason: "launch+3s")
        }
    }

    static func note(_ message: String) {
        guard enabled else { return }
        log.notice("\(message, privacy: .public)")
        append(message)
    }

    static func dump(reason: String) {
        guard enabled else { return }
        note("windows reason=\(reason) count=\(NSApp.windows.count)")
        for window in NSApp.windows {
            note(windowLine(window))
        }
        note(editorTree())
    }

    static func gutterDraw(
        dirty: NSRect,
        bounds: NSRect,
        lines: Int,
        first: Int,
        last: Int,
        color: String,
        api: String
    ) {
        guard enabled else { return }
        drawLogs += 1
        if drawLogs > 80 && drawLogs % 30 != 0 { return }
        note("gutter draw #\(drawLogs) dirty=\(rect(dirty)) bounds=\(rect(bounds)) lines=\(lines) first=\(first) last=\(last) color=\(color) api=\(api)")
    }

    static func keyDown(code: UInt16, before: Int, after: Int) {
        note("keyDown code=\(code) editorLen \(before)->\(after)")
    }

    static func textDidChange(length: Int) {
        note("controlTextDidChange editorLen=\(length)")
    }

    static func stringAssignment(old: Int, new: Int, applied: Bool) {
        let stack = Thread.callStackSymbols.prefix(6).joined(separator: " | ")
        note("stringValue \(old)->\(new) applied=\(applied) stack=\(stack)")
    }

    static func fileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("xyz-diag.log")
    }

    private static func windowLine(_ window: NSWindow) -> String {
        let reason = WorkspaceWindowController.phantomReason(window)
        let controller = window.windowController.map { String(describing: type(of: $0)) } ?? "nil"
        let delegate = window.delegate.map { String(describing: type(of: $0)) } ?? "nil"
        let content = window.contentView.map { String(describing: type(of: $0)) } ?? "nil"
        let ident = window.identifier?.rawValue ?? ""
        return "window class=\(String(describing: type(of: window))) title=\(window.title) id=\(ident) frame=\(rect(window.frame)) visible=\(window.isVisible) alpha=\(window.alphaValue) level=\(window.level.rawValue) style=\(window.styleMask.rawValue) restorable=\(window.isRestorable) controller=\(controller) delegate=\(delegate) content=\(content) phantom=\(reason)"
    }

    private static func editorTree() -> String {
        var lines = ["editor tree"]
        for window in NSApp.windows {
            guard let root = window.contentView else { continue }
            if let pane = findPane(in: root) {
                lines.append("pane window=\(window.title)")
                walk(pane, indent: 1, into: &lines)
            }
        }
        if lines.count == 1 { lines.append("pane none") }
        return lines.joined(separator: "\n")
    }

    private static func findPane(in view: NSView) -> EditorPane? {
        if let pane = view as? EditorPane { return pane }
        for child in view.subviews {
            if let found = findPane(in: child) { return found }
        }
        return nil
    }

    private static func walk(_ view: NSView, indent: Int, into lines: inout [String]) {
        let pad = String(repeating: " ", count: indent * 2)
        let ident = view.identifier?.rawValue ?? ""
        lines.append("\(pad)\(String(describing: type(of: view))) id=\(ident) frame=\(rect(view.frame)) hidden=\(view.isHidden) alpha=\(view.alphaValue) layer=\(view.wantsLayer) opaque=\(view.isOpaque)")
        if indent < 8 {
            for child in view.subviews {
                walk(child, indent: indent + 1, into: &lines)
            }
        }
    }

    private static func rect(_ rect: NSRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    private static func append(_ message: String) {
        let url = fileURL()
        let line = message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
