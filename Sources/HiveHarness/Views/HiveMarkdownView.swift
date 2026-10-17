import AppKit
import SwiftUI

/// 轻量 Markdown:普通段落 + 围栏代码块(带语言标签与复制按钮)。
struct HiveMarkdownView: View {
    let text: String
    var isUser: Bool = false

    private enum Block: Identifiable {
        case text(String)
        case code(language: String, code: String)

        var id: String {
            switch self {
            case .text(let value): return "t-\(value.hashValue)"
            case .code(let language, let code): return "c-\(language)-\(code.hashValue)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    Text(attributed(value))
                        .font(.system(.body, design: .rounded))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    HiveCodeBlock(language: language, code: code)
                }
            }
        }
    }

    private func attributed(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var language = ""

        func flushText() {
            guard !textLines.isEmpty else { return }
            result.append(.text(textLines.joined(separator: "\n")))
            textLines.removeAll()
        }
        func flushCode() {
            guard inCode else { return }
            result.append(.code(language: language, code: codeLines.joined(separator: "\n")))
            codeLines.removeAll()
            language = ""
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushText()
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode {
                codeLines.append(line)
            } else {
                textLines.append(line)
            }
        }
        if inCode { flushCode() }
        flushText()
        if result.isEmpty { result.append(.text(text)) }
        return result
    }
}

private struct HiveCodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.caption2)
                    .foregroundStyle(HiveTheme.amberDeep)
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.035))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(HiveTheme.hairline, lineWidth: 1)
        )
        .frame(maxWidth: 720, alignment: .leading)
    }
}
