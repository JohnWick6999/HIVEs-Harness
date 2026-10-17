import SwiftUI
import HiveHarnessCore

/// 粗粒度推理滑杆:5 档,高等级带不同颜色的彗星尾。
struct CometReasoningSlider: View {
    @Binding var effort: ReasoningEffort
    private let levels = ReasoningEffort.allCases

    var body: some View {
        VStack(spacing: 5) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                GeometryReader { geo in
                    let width = max(1, geo.size.width)
                    let x = CGFloat(effort.index) / CGFloat(max(1, levels.count - 1)) * width
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.09))
                            .frame(height: 6)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [color.opacity(0.45), color],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(6, x), height: 6)
                            .shadow(color: color.opacity(0.25), radius: 5)

                        comet(x: x, time: time)

                        HStack(spacing: 0) {
                            ForEach(Array(levels.enumerated()), id: \.offset) { index, _ in
                                Circle()
                                    .fill(index <= effort.index ? color : Color.primary.opacity(0.18))
                                    .frame(width: index == effort.index ? 7 : 4,
                                           height: index == effort.index ? 7 : 4)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: 22)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                let step = width / CGFloat(max(1, levels.count - 1))
                                let index = Int((value.location.x / step).rounded())
                                let next = levels[min(levels.count - 1, max(0, index))]
                                if next != effort { effort = next }
                            }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                let step = width / CGFloat(max(1, levels.count - 1))
                                let index = Int((value.location.x / step).rounded())
                                let next = levels[min(levels.count - 1, max(0, index))]
                                if next != effort { effort = next }
                            }
                    )
                }
            }
            .frame(height: 22)

            HStack {
                ForEach(levels) { level in
                    Text(level.title)
                        .font(.system(size: 8, weight: level == effort ? .semibold : .regular))
                        .foregroundStyle(level == effort ? color : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private func comet(x: CGFloat, time: TimeInterval) -> some View {
        let count = trailCount
        if count > 0 {
            ForEach(0..<count, id: \.self) { index in
                let drift = sin(time * 2.4 + Double(index) * 0.8) * 1.8
                Circle()
                    .fill(color.opacity(max(0.08, 0.55 - Double(index) * 0.025)))
                    .frame(width: max(1.5, 5 - CGFloat(index) * 0.18),
                           height: max(1.5, 5 - CGFloat(index) * 0.18))
                    .blur(radius: index > count / 2 ? 1.2 : 0)
                    .offset(
                        x: max(0, x - CGFloat(index + 1) * (effort == .max ? 4.2 : 5.2) + CGFloat(drift)),
                        y: CGFloat(drift * 0.6)
                    )
            }
            Circle()
                .fill(color)
                .frame(width: effort == .max ? 10 : 8, height: effort == .max ? 10 : 8)
                .offset(x: x - (effort == .max ? 5 : 4))
                .shadow(color: color.opacity(0.9), radius: effort == .max ? 9 : 5)
            if effort == .max {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [.pink, .purple, .cyan, .pink],
                            center: .center
                        ),
                        lineWidth: 1.4
                    )
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(time * 120))
                    .offset(x: x - 10)
                    .opacity(0.8)
            }
        }
    }

    private var trailCount: Int {
        switch effort {
        case .off: return 0
        case .low: return 3
        case .medium: return 6
        case .high: return 10
        case .max: return 16
        }
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
}
