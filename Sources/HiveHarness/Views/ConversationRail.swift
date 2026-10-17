import SwiftUI
import HiveHarnessCore

/// 右侧对话缩略轨:固定间距短横线 + 悬停左侧摘要,点击跳到对应轮次。
struct ConversationRail: View {
    let turns: [ConversationTurn]
    let onSelect: (UUID) -> Void

    @State private var hovered: UUID?

    private let markHeight: CGFloat = 16
    private let spacing: CGFloat = 2

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: spacing) {
                ForEach(turns) { turn in
                    marker(turn)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
        .frame(width: 28)
        .frame(maxHeight: 420)
        .mask(
            LinearGradient(
                colors: [.clear, .black, .black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.vertical, -18)
        )
        .padding(.leading, 6)
    }

    private func marker(_ turn: ConversationTurn) -> some View {
        let active = turn.id == turns.last?.id
        let hot = hovered == turn.id
        return Button {
            onSelect(turn.targetMessageID)
        } label: {
            Capsule()
                .fill(hot || active ? HiveTheme.amber : Color.primary.opacity(0.20))
                .frame(width: hot || active ? 20 : 12, height: 2)
                .frame(width: 28, height: 16, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside ? turn.id : (hovered == turn.id ? nil : hovered)
        }
        .overlay(alignment: .trailing) {
            if hot {
                preview(turn)
                    .offset(x: 310)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("跳到第 \(turn.index) 轮")
    }

    private func preview(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("第 \(turn.index) 轮")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(HiveTheme.amberDeep)
            Text(turn.userText)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if !turn.assistantText.isEmpty {
                Text(turn.assistantText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HiveTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
