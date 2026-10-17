import SwiftUI
import HiveHarnessCore

/// 对话右侧的轮次轨:悬停显示摘要,点击跳到该轮,可滚动查看更早历史。
struct ConversationRail: View {
    let turns: [ConversationTurn]
    let onSelect: (UUID) -> Void

    @State private var hovered: UUID?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 7) {
                ForEach(turns) { turn in
                    marker(turn)
                }
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 32)
        .background(alignment: .leading) {
            Rectangle()
                .fill(HiveTheme.hairline)
                .frame(width: 1)
                .padding(.vertical, 18)
        }
    }

    private func marker(_ turn: ConversationTurn) -> some View {
        Button {
            onSelect(turn.targetMessageID)
        } label: {
            ZStack {
                Circle()
                    .fill(hovered == turn.id ? HiveTheme.amber.opacity(0.20) : Color.primary.opacity(0.04))
                    .frame(width: 20, height: 20)
                Text("\(turn.index)")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(hovered == turn.id ? HiveTheme.amberDeep : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside ? turn.id : (hovered == turn.id ? nil : hovered)
        }
        .popover(isPresented: Binding(
            get: { hovered == turn.id },
            set: { if !$0, hovered == turn.id { hovered = nil } }
        ), arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 6) {
                Text("第 \(turn.index) 轮")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HiveTheme.amberDeep)
                Text(turn.userText)
                    .font(.caption)
                    .lineLimit(4)
                if !turn.assistantText.isEmpty {
                    Divider()
                    Text(turn.assistantText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }
                Text("点击跳到这一轮")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
        }
    }
}
