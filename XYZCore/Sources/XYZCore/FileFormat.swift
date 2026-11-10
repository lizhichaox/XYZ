import Foundation

/// How a non-text file is shown. Text files have no viewer.
public enum FileViewerKind: Equatable, Sendable {
    case image
    case pdf
    case audiovisual
}

/// What Reading shows for a text file. `.none` means the file has only Source.
public enum FileReading: Equatable, Sendable {
    case none
    case markdown
    case json
    case csv
}

/// A language the plain syntax coloring knows. Markdown keeps its own styling.
public enum SyntaxLanguage: String, Equatable, Sendable {
    case plain
    case markdown
    case json
    case yaml
    case toml
    case xml
    case csv
    case log
    case swift
    case javascript
    case typescript
    case python
    case go
    case rust
    case c
    case shell
    case css
    case html
    case sql
    case ruby
    case java
    case kotlin
    case php
    case ini

    public var label: String {
        switch self {
        case .plain: return "Plain Text"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .xml: return "XML"
        case .csv: return "CSV"
        case .log: return "Log"
        case .swift: return "Swift"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .go: return "Go"
        case .rust: return "Rust"
        case .c: return "C"
        case .shell: return "Shell"
        case .css: return "CSS"
        case .html: return "HTML"
        case .sql: return "SQL"
        case .ruby: return "Ruby"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .php: return "PHP"
        case .ini: return "INI"
        }
    }

    /// Code and configuration files get code editing behavior; prose and logs do not.
    public var isCode: Bool {
        switch self {
        case .plain, .markdown, .csv, .log:
            return false
        default:
            return true
        }
    }
}

/// One file format. Markdown is the first; more register by extension.
public struct FileFormat: Equatable, Sendable {
    public var language: SyntaxLanguage
    public var reading: FileReading
    public var isProse: Bool
    /// Set when the file is shown in a viewer instead of the editor.
    public var viewer: FileViewerKind?
    public var label: String

    public init(
        language: SyntaxLanguage,
        reading: FileReading = .none,
        isProse: Bool = false,
        viewer: FileViewerKind? = nil,
        label: String? = nil
    ) {
        self.language = language
        self.reading = reading
        self.isProse = isProse
        self.viewer = viewer
        self.label = label ?? (viewer == nil ? language.label : language.label)
    }

    /// Code and structured text use a fixed-width face. Prose follows the editor setting.
    public var usesCodeFont: Bool {
        viewer == nil && !isProse && language != .plain && language != .markdown
    }
}

/// Extension map for viewers, syntax, and Reading. Names are matched case-insensitively.
public enum FileFormats {
    /// Extension first. A plain name whose first line is a shell shebang is shell.
    public static func resolved(name: String, text: String) -> FileFormat {
        var format = format(for: name)
        guard format.language == .plain, let detected = shebangLanguage(in: text) else { return format }
        format.language = detected
        format.label = "Shell"
        return format
    }

    /// `#!/bin/bash`, `#!/usr/bin/env bash`, and the `sh` / `zsh` equivalents.
    public static func shebangLanguage(in text: String) -> SyntaxLanguage? {
        let first = text.prefix { $0 != "\n" && $0 != "\r" }
        guard first.hasPrefix("#!") else { return nil }
        let line = first.lowercased()
        if line.contains("bash") || line.contains("zsh") { return .shell }
        if line.contains("/sh") || line.contains("env sh") { return .shell }
        return nil
    }

    /// The language a Markdown fence's info string names, such as `swift` or `bash`.
    /// Unknown or missing names fall back to plain, which keeps the code block in the
    /// monospaced face without inventing colours.
    public static func fenceLanguage(_ info: String) -> SyntaxLanguage {
        let token = info.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" })
            .first
            .map(String.init)?
            .lowercased() ?? ""
        guard !token.isEmpty else { return .plain }
        switch token {
        case "swift": return .swift
        case "js", "javascript", "jsx", "mjs", "cjs": return .javascript
        case "ts", "typescript", "tsx": return .typescript
        case "py", "python": return .python
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c": return .c
        case "sh", "bash", "zsh", "shell", "console": return .shell
        case "json", "jsonc": return .json
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "xml", "html", "xhtml": return .html
        case "css", "scss", "less": return .css
        case "sql": return .sql
        case "rb", "ruby": return .ruby
        case "java": return .java
        case "kt", "kotlin": return .kotlin
        case "php": return .php
        case "ini", "conf", "cfg": return .ini
        case "md", "markdown": return .markdown
        case "csv", "tsv": return .csv
        case "log": return .log
        default: return .plain
        }
    }

    public static func format(for name: String) -> FileFormat {
        let ext = pathExtension(of: name)
        if let viewer = viewerKind(forExtension: ext) {
            return FileFormat(language: .plain, viewer: viewer, label: viewerLabel(viewer, pathExtension: ext))
        }
        switch ext {
        case "md", "markdown":
            return FileFormat(language: .markdown, reading: .markdown, isProse: true)
        case "txt", "text":
            return FileFormat(language: .plain, isProse: true)
        case "json", "jsonc":
            return FileFormat(language: .json, reading: .json)
        case "yaml", "yml":
            return FileFormat(language: .yaml)
        case "toml":
            return FileFormat(language: .toml)
        case "xml", "svg", "plist", "xsd", "xsl":
            return FileFormat(language: .xml, label: ext == "svg" ? "SVG" : "XML")
        case "html", "htm":
            return FileFormat(language: .html)
        case "css", "scss":
            return FileFormat(language: .css, label: ext == "scss" ? "SCSS" : "CSS")
        case "csv", "tsv":
            return FileFormat(language: .csv, reading: .csv, label: ext == "tsv" ? "TSV" : "CSV")
        case "log":
            return FileFormat(language: .log)
        case "swift":
            return FileFormat(language: .swift)
        case "js", "jsx", "mjs", "cjs":
            return FileFormat(language: .javascript)
        case "ts", "tsx":
            return FileFormat(language: .typescript)
        case "py":
            return FileFormat(language: .python)
        case "go":
            return FileFormat(language: .go)
        case "rs":
            return FileFormat(language: .rust)
        case "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh":
            return FileFormat(language: .c, label: ext == "h" || ext == "hpp" || ext == "hh" ? "C Header" : "C")
        case "java":
            return FileFormat(language: .java)
        case "kt", "kts":
            return FileFormat(language: .kotlin)
        case "rb":
            return FileFormat(language: .ruby)
        case "php":
            return FileFormat(language: .php)
        case "sh", "bash", "zsh", "command", "tool":
            return FileFormat(language: .shell)
        case "sql":
            return FileFormat(language: .sql)
        case "ini", "cfg", "conf", "env":
            return FileFormat(language: .ini, label: ext == "env" ? "ENV" : "INI")
        default:
            return FileFormat(language: .plain)
        }
    }

    public static func isViewerExtension(_ name: String) -> Bool {
        viewerKind(forExtension: pathExtension(of: name)) != nil
    }

    /// Names whose bytes may be Windows-1252 or heuristic UTF-16 when they are not Unicode.
    public static func isTextualName(_ name: String) -> Bool {
        let file = (name as NSString).lastPathComponent.lowercased()
        if textualBasenames.contains(file) { return true }
        let ext = pathExtension(of: name)
        if ext.isEmpty {
            // Foundation reports no path extension for a dotfile. `.gitignore`,
            // `.editorconfig`, and `.env` still come from the text lists; an
            // unknown dotfile (`.DS_Store`) stays binary.
            guard file.hasPrefix("."), file.count > 1 else { return false }
            return textualExtensions.contains(String(file.dropFirst()))
        }
        if viewerKind(forExtension: ext) != nil { return false }
        return textualExtensions.contains(ext)
    }

    public static func viewerKind(forExtension ext: String) -> FileViewerKind? {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns":
            return .image
        case "pdf":
            return .pdf
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "mp4", "mov", "m4v":
            return .audiovisual
        default:
            return nil
        }
    }

    private static func viewerLabel(_ kind: FileViewerKind, pathExtension ext: String) -> String {
        switch kind {
        case .image:
            return ext.uppercased()
        case .pdf:
            return "PDF"
        case .audiovisual:
            switch ext {
            case "mp4", "mov", "m4v": return "Video"
            default: return "Audio"
            }
        }
    }

    private static func pathExtension(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    private static let textualBasenames: Set<String> = [
        "makefile", "dockerfile", "license", "gemfile", "rakefile", "readme",
    ]

    private static let textualExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "json", "jsonc", "yaml", "yml", "toml",
        "xml", "svg", "plist", "html", "htm", "css", "scss", "csv", "tsv", "log",
        "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "go", "rs",
        "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hh", "java", "kt", "kts",
        "rb", "php", "sh", "bash", "zsh", "command", "tool", "sql", "ini", "cfg", "conf", "env",
        "gitignore", "gitattributes", "editorconfig", "lock", "gradle", "mod", "sum",
        "strings", "xcconfig", "pbxproj", "entitlements", "storyboard", "xib",
    ]
}
