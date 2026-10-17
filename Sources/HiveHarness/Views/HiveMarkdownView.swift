import AppKit
import SwiftUI
import HiveHarnessCore

/// 轻量 Markdown:标题/段落/列表/引用/代码块/分隔线。
struct HiveMarkdownView: View {
    let text: String
    var isUser: Bool = false

    private var blocks: [MarkdownBlock] {
        let parsed = MarkdownParser.parse(text)
        return parsed.isEmpty ? [.paragraph(text)] : parsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.top, index == 0 ? 0 : topSpacing(block))
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, value):
            Text(attributed(value))
                .font(.system(size: headingSize(level), weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let value):
            if let table = MarkdownTableParser.parse(value) {
                MarkdownTableView(table: table)
            } else {
                Text(attributed(value))
                    .font(.system(.body, design: .rounded))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle()
                            .fill(HiveTheme.amber)
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(attributed(item))
                            .font(.system(.body, design: .rounded))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(index + 1).")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(HiveTheme.amberDeep)
                            .frame(width: 18, alignment: .trailing)
                        Text(attributed(item))
                            .font(.system(.body, design: .rounded))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let value):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(HiveTheme.amber.opacity(0.6))
                    .frame(width: 3)
                Text(attributed(value))
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

        case let .code(language, code):
            HiveCodeBlock(language: language, code: code)

        case .divider:
            Rectangle()
                .fill(HiveTheme.hairline)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func attributed(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 20
        case 3: return 17
        case 4: return 15
        default: return 14
        }
    }

    private func topSpacing(_ block: MarkdownBlock) -> CGFloat {
        switch block {
        case .heading(let level, _): return level <= 2 ? 7 : 4
        case .divider: return 3
        default: return 0
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                        cell(header, header: true)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            cell(value, header: false)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(HiveTheme.hairline, lineWidth: 1)
            )
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func cell(_ value: String, header: Bool) -> some View {
        Text(inline(value))
            .font(.system(header ? .caption : .caption2, design: .rounded))
            .fontWeight(header ? .semibold : .regular)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(minWidth: 70, alignment: .leading)
            .background(header ? Color.primary.opacity(0.055) : Color.clear)
            .overlay(alignment: .trailing) {
                Rectangle().fill(HiveTheme.hairline).frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(HiveTheme.hairline).frame(height: 1)
            }
    }

    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
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
