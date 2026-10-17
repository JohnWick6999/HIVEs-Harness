import Foundation

/// 轻量 Markdown 块模型(标题/段落/列表/引用/代码/分隔线)。
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case quote(String)
    case code(language: String, code: String)
    case divider
}

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var quote: [String] = []
        var code: [String] = []
        var language = ""
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        func flushLists() {
            if !bullets.isEmpty {
                blocks.append(.bullet(bullets))
                bullets.removeAll()
            }
            if !ordered.isEmpty {
                blocks.append(.ordered(ordered))
                ordered.removeAll()
            }
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote.removeAll()
        }
        func flushAll() {
            flushParagraph()
            flushLists()
            flushQuote()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inCode {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: language, code: code.joined(separator: "\n")))
                    code.removeAll()
                    language = ""
                    inCode = false
                } else {
                    code.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushAll()
                language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inCode = true
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if let heading = parseHeading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if isDivider(trimmed) {
                flushAll()
                blocks.append(.divider)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushLists()
                var value = String(trimmed.dropFirst())
                if value.hasPrefix(" ") { value.removeFirst() }
                quote.append(value)
                continue
            }
            if let item = parseBullet(trimmed) {
                flushParagraph()
                flushQuote()
                if !ordered.isEmpty { flushLists() }
                bullets.append(item)
                continue
            }
            if let item = parseOrdered(trimmed) {
                flushParagraph()
                flushQuote()
                if !bullets.isEmpty { flushLists() }
                ordered.append(item)
                continue
            }
            flushQuote()
            flushLists()
            paragraph.append(line)
        }
        if inCode {
            blocks.append(.code(language: language, code: code.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        let count = line.prefix { $0 == "#" }.count
        guard (1...6).contains(count) else { return nil }
        let text = String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: count, text: text)
    }

    private static func parseBullet(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func parseOrdered(_ line: String) -> String? {
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }
        guard index > line.startIndex, index < line.endIndex else { return nil }
        guard line[index] == "." || line[index] == ")" else { return nil }
        let after = line.index(after: index)
        guard after < line.endIndex, line[after] == " " else { return nil }
        let text = String(line[line.index(after: after)...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        return line.allSatisfy { $0 == "-" || $0 == "*" || $0 == "_" }
    }
}
