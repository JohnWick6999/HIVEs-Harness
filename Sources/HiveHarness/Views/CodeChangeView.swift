import SwiftUI
import HiveHarnessCore

/// 聊天底部的代码变更悬浮提示:悬停查看行级 diff。
struct CodeChangeBadge: View {
    let changes: [FileChange]

    @State private var pinned = false

    private var added: Int { changes.reduce(0) { $0 + $1.addedLines } }
    private var removed: Int { changes.reduce(0) { $0 + $1.removedLines } }

    var body: some View {
        Button {
            pinned.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(HiveTheme.amberDeep)
                Text("\(changes.count) 个文件")
                    .fontWeight(.medium)
                Text("+\(added)")
                    .foregroundStyle(.green)
                    .monospacedDigit()
                Text("−\(removed)")
                    .foregroundStyle(.red)
                    .monospacedDigit()
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(HiveTheme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            // 悬停即固定打开,方便把鼠标移入 diff 面板;再次点击徽章关闭。
            if inside { pinned = true }
        }
        .popover(isPresented: $pinned, arrowEdge: .bottom) {
            CodeChangeDetailView(changes: changes)
        }
        .help("悬停查看代码变更;点击固定/关闭")
    }
}

private struct CodeChangeDetailView: View {
    let changes: [FileChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(HiveTheme.amberDeep)
                Text("代码变更")
                    .font(.headline)
                Spacer()
                Text("\(changes.count) 个文件")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(changes, id: \.path) { change in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(change.fileName)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("+\(change.addedLines)")
                                    .foregroundStyle(.green)
                                Text("−\(change.removedLines)")
                                    .foregroundStyle(.red)
                            }
                            Text(change.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)

                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(change.diff.prefix(160))) { line in
                                    diffRow(line)
                                }
                                if change.diff.count > 160 {
                                    Text("… 仅显示前 160 行")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .padding(6)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(HiveTheme.hairline, lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 640, height: 420)
    }

    private func diffRow(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "")
                .frame(width: 28, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newLine.map(String.init) ?? "")
                .frame(width: 28, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(sign(line.kind))
                .frame(width: 16)
                .foregroundStyle(color(line.kind))
            Text(line.text.isEmpty ? " " : line.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(background(line.kind))
    }

    private func sign(_ kind: DiffLineKind) -> String {
        switch kind {
        case .context: return " "
        case .added: return "+"
        case .removed: return "−"
        }
    }

    private func color(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .context: return .secondary
        case .added: return .green
        case .removed: return .red
        }
    }

    private func background(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .context: return .clear
        case .added: return .green.opacity(0.12)
        case .removed: return .red.opacity(0.12)
        }
    }
}
