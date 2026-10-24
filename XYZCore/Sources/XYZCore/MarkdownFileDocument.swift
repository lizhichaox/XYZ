import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI document adapter for Markdown and plain text.
///
/// The value that is saved is the UTF-8 text held here. The editor writes into
/// `storeEditorText` on each change and the system calls `snapshot` when it saves.
/// Typing undo is owned by the TextKit 2 view, which is pointed at the document
/// scene's undo manager so SwiftUI can track the dirty state without copying the
/// buffer through a SwiftUI binding.
public final class MarkdownFileDocument: ReferenceFileDocument {
    public typealias Snapshot = String

    public let objectWillChange = ObservableObjectPublisher()

    public static var readableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    public static var writableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    private let lock = NSLock()
    private var storage: String

    public init() {
        storage = ""
    }

    public required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        storage = try TextDocument(data: data).text
    }

    /// Latest text, safe to read from the save path.
    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Replace the stored text. Does not register its own undo action.
    public func storeEditorText(_ newText: String) {
        lock.lock()
        storage = newText
        lock.unlock()
    }

    public func snapshot(contentType: UTType) throws -> String {
        // Markdown and plain text share one UTF-8 snapshot. The system picks the type.
        _ = contentType
        return text
    }

    public func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        _ = configuration.contentType
        return FileWrapper(regularFileWithContents: TextDocument(text: snapshot).data())
    }
}
