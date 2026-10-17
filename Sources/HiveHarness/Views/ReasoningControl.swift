import SwiftUI
import HiveHarnessCore

/// 粗粒度推理滑杆:5 档,切换时弹簧、光晕和缩放动画不同。
struct ReasoningControl: View {
    @Binding var effort: ReasoningEffort
    @State private var burst = false
    @State private var appeared = false

    private let levels = ReasoningEffort.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 9, weight: .semibold))
                Text("推理 \(effort.title)")
                    .font(.system(size: 9, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 5)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.45), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(5, geo.size.width * fraction), height: 5)
                        .shadow(color: color.opacity(0.35), radius: burst ? 7 : 3)
                    HStack(spacing: 0) {
                        ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                            Circle()
                                .fill(index <= effort.index ? color : Color.primary.opacity(0.16))
                                .frame(width: index == effort.index ? 8 : 4, height: index == effort.index ? 8 : 4)
                                .overlay {
                                    if index == effort.index {
                                        Circle()
                                            .stroke(color.opacity(0.35), lineWidth: burst ? 3 : 1)
                                            .scaleEffect(burst ? 1.8 : 1)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .animation(.spring(response: 0.35, dampingFraction: 0.62), value: effort)
                                .animation(.easeOut(duration: 0.5), value: burst)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let step = geo.size.width / CGFloat(max(1, levels.count - 1))
                            let index = Int((value.location.x / step).rounded())
                            let clamped = min(levels.count - 1, max(0, index))
                            let next = levels[clamped]
                            guard next != effort else { return }
                            effort = next
                            pulse()
                        }
                )
            }
            .frame(height: 14)
        }
        .frame(width: 120)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 3)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { appeared = true }
        }
        .help("推理等级:\(effort.title)")
    }

    private var fraction: CGFloat {
        guard levels.count > 1 else { return 0 }
        return CGFloat(effort.index) / CGFloat(levels.count - 1)
    }

    private var color: Color {
        switch effort {
        case .off: return .secondary
        case .low: return .cyan
        case .medium: return HiveTheme.amber
        case .high: return .orange
        case .max: return .pink
        }
    }

    private func pulse() {
        burst = true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) {
            burst = false
        }
    }
}
