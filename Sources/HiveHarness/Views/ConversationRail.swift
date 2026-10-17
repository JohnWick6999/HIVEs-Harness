import SwiftUI
import HiveHarnessCore

/// 左侧对话缩略轨:短横线 + 悬停摘要 popover,点击跳转。
struct ConversationRail: View {
    let turns: [ConversationTurn]
    let onSelect: (UUID) -> Void

    @State private var hovered: UUID?
    @State private var hideTask: Task<Void, Never>?

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
        .onDisappear { hideTask?.cancel() }
    }

    private func marker(_ turn: ConversationTurn) -> some View {
        let active = turn.id == turns.last?.id
        let hot = hovered == turn.id
        return Button {
            onSelect(turn.targetMessageID)
        } label: {
            Capsule()
                .fill(hot || active ? HiveTheme.amber : Color.primary.opacity(0.24))
                .frame(width: hot || active ? 20 : 13, height: 2)
                .frame(width: 28, height: 16, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hideTask?.cancel()
                hovered = turn.id
            } else if hovered == turn.id {
                scheduleHide()
            }
        }
        .popover(isPresented: Binding(
            get: { hovered == turn.id },
            set: { if !$0, hovered == turn.id { hovered = nil } }
        ), arrowEdge: .trailing) {
            preview(turn)
                .onHover { inside in
                    if inside {
                        hideTask?.cancel()
                    } else {
                        scheduleHide()
                    }
                }
        }
        .help("跳到第 \(turn.index) 轮")
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                hovered = nil
            }
        }
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
        .background(.regularMaterial)
    }
}
