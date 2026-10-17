import Foundation

public struct MarkdownTable: Sendable, Equatable {
    public var headers: [String]
    public var rows: [[String]]

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }
}

public enum MarkdownTableParser {
    /// 解析段落里的管道表格;不是表格返回 nil。
    public static func parse(_ text: String) -> MarkdownTable? {
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2,
              lines[0].contains("|"),
              lines[1].contains("|")
        else { return nil }

        let headers = cells(lines[0])
        let separator = cells(lines[1])
        guard !headers.isEmpty,
              headers.count == separator.count,
              separator.allSatisfy(isSeparator)
        else { return nil }

        var rows: [[String]] = []
        for line in lines.dropFirst(2) {
            guard line.contains("|") else { break }
            var row = cells(line)
            if row.count < headers.count {
                row += Array(repeating: "", count: headers.count - row.count)
            }
            rows.append(Array(row.prefix(headers.count)))
        }
        return MarkdownTable(headers: headers, rows: rows)
    }

    private static func cells(_ line: String) -> [String] {
        var value = line
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparator(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
    }
}
