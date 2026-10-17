import SwiftUI
import HiveHarnessCore

/// 左侧对话缩略轨:固定列短横线;整条区域命中,悬停摘要,点击跳转。
struct ConversationRail: View {
    let turns: [ConversationTurn]
    let onSelect: (UUID) -> Void

    @State private var hovered: UUID?

    private let railWidth: CGFloat = 28
    private let maxHeight: CGFloat = 420

    private var pitch: CGFloat {
        guard !turns.isEmpty else { return 0 }
        return min(18, max(4, maxHeight / CGFloat(turns.count)))
    }

    private var railHeight: CGFloat {
        max(1, CGFloat(turns.count) * pitch)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(turns) { turn in
                    mark(turn)
                        .frame(height: pitch)
                }
            }
            .frame(width: railWidth, alignment: .trailing)
            .allowsHitTesting(false)

            if let hoveredTurn = turns.first(where: { $0.id == hovered }) {
                preview(hoveredTurn)
                    .offset(
                        x: railWidth + 8,
                        y: yPosition(of: hoveredTurn) - 12
                    )
                    .allowsHitTesting(false)
                    .zIndex(2)
            }
        }
        .frame(width: railWidth, height: railHeight, alignment: .topLeading)
        .padding(.leading, 6)
        .background(Color.primary.opacity(0.001))
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hovered = turn(at: location.y)?.id
            case .ended:
                hovered = nil
            }
        }
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    if let turn = turn(at: value.location.y) {
                        hovered = nil
                        onSelect(turn.targetMessageID)
                    }
                }
        )
    }

    private func mark(_ turn: ConversationTurn) -> some View {
        let active = turn.id == turns.last?.id
        let hot = hovered == turn.id
        return Capsule()
            .fill(hot || active ? HiveTheme.amber : Color.primary.opacity(0.26))
            .frame(width: hot || active ? 20 : 13, height: 2)
            .frame(width: railWidth, alignment: .trailing)
            .help("跳到第 \(turn.index) 轮")
    }

    private func turn(at y: CGFloat) -> ConversationTurn? {
        guard !turns.isEmpty, pitch > 0 else { return nil }
        let index = Int((y / pitch).rounded(.down))
        return turns[min(turns.count - 1, max(0, index))]
    }

    private func yPosition(of turn: ConversationTurn) -> CGFloat {
        guard let index = turns.firstIndex(where: { $0.id == turn.id }) else { return 0 }
        return CGFloat(index) * pitch + pitch / 2
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
