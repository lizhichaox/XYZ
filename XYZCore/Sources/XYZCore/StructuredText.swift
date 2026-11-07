import Foundation

/// Pretty-printed JSON for Reading. Invalid JSON returns nil and the caller shows the source.
public enum JSONText {
    public static func pretty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(object) || object is NSNumber || object is String || object is NSNull else {
            return nil
        }
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        ), let string = String(data: pretty, encoding: .utf8) else {
            return nil
        }
        return string.hasSuffix("\n") ? String(string.dropLast()) : string
    }
}

public struct CSVGrid: Equatable, Sendable {
    public var rows: [[String]]
    /// True when `rows` stops before the end of the file.
    public var truncated: Bool
    public var rowCount: Int

    public init(rows: [[String]], truncated: Bool, rowCount: Int) {
        self.rows = rows
        self.truncated = truncated
        self.rowCount = rowCount
    }
}

/// A small CSV and TSV reader for the Reading view. Quotes follow the usual doubled-quote rule.
public enum CSVText {
    public static let rowLimit = 500

    public static func parse(_ text: String, rowLimit: Int = rowLimit) -> CSVGrid {
        let delimiter = delimiter(in: text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var total = 0
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        let cap = max(0, rowLimit)
        let delimiterScalar = delimiter.unicodeScalars.first ?? ","
        func finishField() {
            row.append(field)
            field = ""
        }
        func finishRow() {
            finishField()
            let finished = row
            row = []
            if finished.allSatisfy(\.isEmpty) { return }
            total += 1
            if rows.count < cap {
                rows.append(finished)
            }
        }
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    let next = scalars.index(after: index)
                    if next < scalars.endIndex, scalars[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else if scalar == "\"", field.isEmpty {
                inQuotes = true
            } else if scalar == delimiterScalar {
                finishField()
            } else if scalar == "\n" || scalar == "\r" {
                if scalar == "\r" {
                    let next = scalars.index(after: index)
                    if next < scalars.endIndex, scalars[next] == "\n" {
                        index = next
                    }
                }
                finishRow()
            } else {
                field.unicodeScalars.append(scalar)
            }
            index = scalars.index(after: index)
        }
        if inQuotes || !field.isEmpty || !row.isEmpty {
            finishRow()
        }
        return CSVGrid(rows: rows, truncated: total > rows.count, rowCount: total)
    }

    /// A tab-separated file uses tabs. Everything else uses commas.
    static func delimiter(in text: String) -> Character {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let tabs = first.filter { $0 == "\t" }.count
        let commas = first.filter { $0 == "," }.count
        return tabs > commas ? "\t" : ","
    }
}
