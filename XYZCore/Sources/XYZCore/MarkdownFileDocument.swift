import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI document adapter for Markdown and plain text.
///
/// The value that is saved is the text held here, in the encoding the file was read
/// with (`TextDocument`). The editor writes into `storeEditorText` on each change and
/// the system calls `snapshot` when it saves. Typing undo is owned by the TextKit view,
/// which is pointed at the document scene's undo manager so SwiftUI can track the dirty
/// state without copying the buffer through a SwiftUI binding.
public final class MarkdownFileDocument: ReferenceFileDocument {
    public typealias Snapshot = String

    /// Required by `ObservableObject`. The document does not publish: the text arrives
    /// from the text view through `storeEditorText`, and the window's edited state comes
    /// from the undo manager the editor registers typing with. Sending on every keystroke
    /// would rebuild the document scene on each key for no visible change.
    public let objectWillChange = ObservableObjectPublisher()

    public static var readableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    public static var writableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    private let lock = NSLock()
    private var storage: TextDocument

    public init() {
        storage = TextDocument()
    }

    public required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // The document scene reads what the document browser or ⌘O was given: any text
        // encoding the rest of the app reads, not only UTF-8.
        storage = try TextDocument(data: data)
    }

    /// Latest text, safe to read from the save path.
    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage.text
    }

    /// Replace the stored text. Does not register its own undo action.
    public func storeEditorText(_ newText: String) {
        lock.lock()
        storage.text = newText
        lock.unlock()
    }

    public func snapshot(contentType: UTType) throws -> String {
        // Markdown and plain text share one snapshot. The system picks the type.
        _ = contentType
        return text
    }

    public func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        _ = configuration.contentType
        lock.lock()
        let encoding = storage.encoding
        lock.unlock()
        return FileWrapper(regularFileWithContents: TextDocument(text: snapshot, encoding: encoding).data())
    }
}
