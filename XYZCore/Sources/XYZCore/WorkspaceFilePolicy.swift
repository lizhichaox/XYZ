import Foundation

public enum WorkspaceFileKind: Equatable, Sendable {
    /// Editor and Markdown preview.
    case markdown
    /// Editor only. Covers source, JSON, and dotfiles that are text.
    case plainText
    /// Not shown in the editor.
    case binary
    /// Over the in-memory edit limit.
    case tooLarge
}

/// What an 8 KiB prefix says about the rest of the file.
public enum WorkspaceUTF8Sample: Equatable, Sendable {
    /// Valid UTF-8, after dropping an unfinished character at the cut.
    case text
    /// NUL, or bytes that cannot be UTF-8.
    case binary
    /// The sample is shorter than the file and the failure is on the cut.
    /// Read the whole file before deciding.
    case ambiguous
}

public enum WorkspaceFileClassifier {
    public static let sampleLimit = 8_192
    /// Files larger than this stay out of the text view.
    public static let editLimit = 5_000_000

    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let plainExtensions: Set<String> = ["txt", "text"]

    /// `fullFile` is used when the sample ends on an ambiguous cut.
    /// `.md`, `.markdown`, and `.txt` are not marked binary from a short sample alone.
    /// A NUL byte is still binary, including in those names.
    public static func kind(
        name: String,
        byteCount: Int,
        sample: Data,
        fullFile: Data? = nil
    ) -> WorkspaceFileKind {
        if byteCount > editLimit {
            return .tooLarge
        }
        if let fullFile, needsFullRead(byteCount: byteCount, sample: sample) {
            return classify(name: name, byteCount: fullFile.count, sample: fullFile)
        }
        return classify(name: name, byteCount: byteCount, sample: sample)
    }

    /// True when `sample` is a prefix and its UTF-8 status depends on bytes past the cut.
    public static func needsFullRead(byteCount: Int, sample: Data) -> Bool {
        guard byteCount <= editLimit, sample.count < byteCount, !sample.contains(0) else {
            return false
        }
        return utf8Sample(sample, byteCount: byteCount) == .ambiguous
    }

    public static func utf8Sample(_ sample: Data, byteCount: Int) -> WorkspaceUTF8Sample {
        if sample.contains(0) {
            return .binary
        }
        let longer = sample.count < byteCount
        switch scan(sample) {
        case .valid:
            return .text
        case .incompleteTail:
            return longer ? .text : .binary
        case .invalid(let index):
            if longer && index >= sample.count - 3 {
                return .ambiguous
            }
            return .binary
        }
    }

    private static func classify(name: String, byteCount: Int, sample: Data) -> WorkspaceFileKind {
        if byteCount > editLimit {
            return .tooLarge
        }
        if sample.contains(0) {
            return .binary
        }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let decision = utf8Sample(sample, byteCount: byteCount)
        switch decision {
        case .text:
            return kind(forExtension: ext)
        case .binary, .ambiguous:
            // A prefix that fails UTF-8 is not enough to reject these names.
            // The editor still checks the whole file before showing it.
            if sample.count < byteCount && (markdownExtensions.contains(ext) || plainExtensions.contains(ext)) {
                return kind(forExtension: ext)
            }
            return .binary
        }
    }

    private static func kind(forExtension ext: String) -> WorkspaceFileKind {
        if markdownExtensions.contains(ext) {
            return .markdown
        }
        return .plainText
    }

    private enum Scan {
        case valid
        case incompleteTail
        case invalid(at: Int)
    }

    /// Walks UTF-8. A partial character at the end is `incompleteTail`, not an error.
    private static func scan(_ data: Data) -> Scan {
        if data.isEmpty { return .valid }
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            let width = sequenceWidth(lead)
            if width == 0 {
                return .invalid(at: index)
            }
            let have = bytes.count - index
            if have < width {
                if validPrefix(bytes, start: index, have: have, width: width) {
                    return .incompleteTail
                }
                return .invalid(at: index)
            }
            if !validSequence(bytes, start: index, width: width) {
                return .invalid(at: index)
            }
            index += width
        }
        return .valid
    }

    private static func sequenceWidth(_ lead: UInt8) -> Int {
        if lead < 0x80 { return 1 }
        if lead >= 0xC2 && lead <= 0xDF { return 2 }
        if lead >= 0xE0 && lead <= 0xEF { return 3 }
        if lead >= 0xF0 && lead <= 0xF4 { return 4 }
        return 0
    }

    private static func validSequence(_ bytes: [UInt8], start: Int, width: Int) -> Bool {
        validPrefix(bytes, start: start, have: width, width: width)
    }

    /// `have` is how many bytes of a `width`-byte character are present, including the lead.
    private static func validPrefix(_ bytes: [UInt8], start: Int, have: Int, width: Int) -> Bool {
        guard have >= 1, have <= width else { return false }
        let lead = bytes[start]
        if have >= 2 {
            let second = bytes[start + 1]
            guard isContinuation(second) else { return false }
            switch lead {
            case 0xE0 where second < 0xA0: return false
            case 0xED where second > 0x9F: return false
            case 0xF0 where second < 0xA0: return false
            case 0xF4 where second > 0x8F: return false
            default: break
            }
        }
        if have >= 3 {
            for offset in 2..<have {
                if !isContinuation(bytes[start + offset]) { return false }
            }
        }
        return true
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte >= 0x80 && byte <= 0xBF
    }
}

public enum WorkspaceDiskChange: Equatable, Sendable {
    case ignore
    case reload
    case conflict
}

public enum WorkspaceWriteDecision: Equatable, Sendable {
    case write
    case upToDate
    case conflict
}

/// Decides how an editor buffer and the bytes on disk can meet without a silent overwrite.
public enum WorkspaceFilePolicy {
    /// `disk` was read because the file changed under us. Local edits that are not saved win a conflict.
    public static func interpretChange(editor: String, lastSaved: String, disk: String) -> WorkspaceDiskChange {
        if disk == editor || disk == lastSaved {
            return .ignore
        }
        if editor == lastSaved {
            return .reload
        }
        return .conflict
    }

    /// `disk` is nil when the file is gone. A deleted file is recreated only when the user asks to overwrite.
    public static func decideWrite(editor: String, lastSaved: String, disk: String?, force: Bool) -> WorkspaceWriteDecision {
        guard let disk else {
            if force {
                return .write
            }
            return editor == lastSaved ? .upToDate : .conflict
        }
        if editor == disk {
            return .upToDate
        }
        if force || disk == lastSaved {
            return .write
        }
        return .conflict
    }
}
