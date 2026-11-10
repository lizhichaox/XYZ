import Foundation

/// Tags written as `#tag` in Markdown, outside fenced and inline code.
public enum TagIndex {
    public static func tags(in text: String) -> Set<String> {
        guard text.contains("#") else { return [] }
        let ns = text as NSString
        var result: Set<String> = []
        var location = 0
        var inFence = false
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            var content = lineRange
            while content.length > 0 {
                let last = ns.character(at: NSMaxRange(content) - 1)
                if last == 0x0A || last == 0x0D {
                    content.length -= 1
                } else {
                    break
                }
            }
            let line = ns.substring(with: content)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
            } else if !inFence {
                for tag in tags(inLine: line) {
                    result.insert(tag)
                }
            }
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
        }
        return result
    }

    private static func tags(inLine line: String) -> [String] {
        let visible = withoutInlineCode(line)
        guard visible.contains("#"), let regex = tagRegex else { return [] }
        let ns = visible as NSString
        return regex.matches(in: visible, options: [], range: NSRange(location: 0, length: ns.length)).compactMap {
            let tag = ns.substring(with: $0.range(at: 1))
            guard tag.rangeOfCharacter(from: .letters) != nil else { return nil }
            return tag
        }
    }

    private static func withoutInlineCode(_ line: String) -> String {
        guard line.contains("`") else { return line }
        var result = ""
        var inCode = false
        for character in line {
            if character == "`" {
                inCode.toggle()
                result.append(" ")
            } else {
                result.append(inCode ? " " : character)
            }
        }
        return result
    }

    private static let tagRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])#([\p{L}\p{N}_/-]+)"#
    )
}
