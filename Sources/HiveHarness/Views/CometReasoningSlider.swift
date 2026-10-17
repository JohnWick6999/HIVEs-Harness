import SwiftUI
import HiveHarnessCore

/// 粗粒度推理滑杆:更厚的能量轨道 + 流光/呼吸光晕/彗尾/环绕粒子。
struct CometReasoningSlider: View {
    @Binding var effort: ReasoningEffort
    private let levels = ReasoningEffort.allCases

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                GeometryReader { geo in
                    let width = max(1, geo.size.width)
                    let x = CGFloat(effort.index) / CGFloat(max(1, levels.count - 1)) * width
                    ZStack(alignment: .leading) {
                        // 厚底座
                        Capsule()
                            .fill(Color.primary.opacity(0.075))
                            .frame(height: 16)
                            .overlay(
                                Capsule()
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )

                        // 呼吸光晕
                        if effort != .off {
                            Capsule()
                                .fill(color.opacity(0.26 + 0.10 * sin(time * 2.1)))
                                .frame(width: max(10, x), height: 28)
                                .blur(radius: 12)
                                .opacity(0.85)
                        }

                        // 已选能量轨道
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [color.opacity(0.48), color, color.opacity(0.82)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, x), height: 16)
                            .overlay {
                                if effort != .off {
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [.clear, .white.opacity(0.48), .clear],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: 46)
                                        .offset(x: CGFloat((sin(time * 1.6) + 1) / 2) * max(0, x - 46))
                                        .blendMode(.plusLighter)
                                }
                            }
                            .shadow(color: color.opacity(0.38), radius: 8)

                        // 轨道内向上漂浮的能量点
                        if effort != .off {
                            ForEach(0..<flowCount, id: \.self) { index in
                                let progress = (time * 0.16 + Double(index) / Double(max(1, flowCount)))
                                    .truncatingRemainder(dividingBy: 1)
                                Circle()
                                    .fill(color.opacity(0.65))
                                    .frame(width: 2.5, height: 2.5)
                                    .offset(
                                        x: CGFloat(progress) * max(8, x),
                                        y: sin(time * 3.0 + Double(index) * 1.2) * 5
                                    )
                                    .blur(radius: 0.4)
                            }
                        }

                        // 彗尾 + 滑块头
                        comet(x: x, time: time)

                        // 5 个档位节点
                        HStack(spacing: 0) {
                            ForEach(Array(levels.enumerated()), id: \.offset) { index, _ in
                                Circle()
                                    .fill(index <= effort.index ? color : Color.primary.opacity(0.2))
                                    .frame(
                                        width: index == effort.index ? 10 : 6,
                                        height: index == effort.index ? 10 : 6
                                    )
                                    .shadow(
                                        color: index == effort.index ? color.opacity(0.8) : .clear,
                                        radius: index == effort.index ? 7 : 0
                                    )
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: 56)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                update(value.location.x, width: width)
                            }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                update(value.location.x, width: width)
                            }
                    )
                }
            }
            .frame(height: 56)

            HStack(spacing: 0) {
                ForEach(levels) { level in
                    Text(level.title)
                        .font(.system(size: 9, weight: level == effort ? .bold : .regular))
                        .foregroundStyle(level == effort ? color : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(level == effort ? 1.06 : 1)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: effort)
                }
            }
        }
        .frame(height: 78)
    }

    private func update(_ locationX: CGFloat, width: CGFloat) {
        let step = width / CGFloat(max(1, levels.count - 1))
        let index = Int((locationX / step).rounded())
        let next = levels[min(levels.count - 1, max(0, index))]
        if next != effort { effort = next }
    }

    @ViewBuilder
    private func comet(x: CGFloat, time: TimeInterval) -> some View {
        let count = trailCount
        if count > 0 {
            ForEach(0..<count, id: \.self) { index in
                let drift = sin(time * 2.2 + Double(index) * 0.7) * 2.2
                let size = max(1.8, 7 - CGFloat(index) * 0.20)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.15)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: size, height: size)
                    .blur(radius: index > count / 2 ? 1.6 : 0.3)
                    .offset(
                        x: max(0, x - CGFloat(index + 1) * (effort == .max ? 4.8 : 5.8) + CGFloat(drift)),
                        y: CGFloat(drift * 0.7)
                    )
            }

            // 轨道头光晕
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: effort == .max ? 34 : 24,
                       height: effort == .max ? 34 : 24)
                .blur(radius: 9)
                .offset(x: x - (effort == .max ? 17 : 12))

            // 滑块头
            Circle()
                .fill(.white)
                .overlay(Circle().fill(color.opacity(0.55)).padding(2))
                .frame(width: effort == .max ? 20 : 16,
                       height: effort == .max ? 20 : 16)
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.9), lineWidth: 1.2)
                )
                .offset(x: x - (effort == .max ? 10 : 8))
                .shadow(color: color.opacity(0.95), radius: effort == .max ? 12 : 7)

            if effort == .max {
                // 极高:旋转色环 + 环绕粒子
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [.pink, .purple, .cyan, .white.opacity(0.8), .pink],
                            center: .center
                        ),
                        lineWidth: 2
                    )
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(time * 160))
                    .offset(x: x - 15)
                    .opacity(0.85)

                ForEach(0..<10, id: \.self) { index in
                    let angle = time * 1.8 + Double(index) / 10 * .pi * 2
                    Circle()
                        .fill(index.isMultiple(of: 2) ? Color.pink : Color.cyan)
                        .frame(width: 3, height: 3)
                        .offset(
                            x: x + CGFloat(cos(angle)) * 22,
                            y: CGFloat(sin(angle)) * 16
                        )
                        .shadow(color: .pink.opacity(0.8), radius: 4)
                }
            } else if effort == .high {
                Circle()
                    .stroke(color.opacity(0.45), lineWidth: 1)
                    .frame(width: 26, height: 26)
                    .scaleEffect(1 + 0.12 * sin(time * 3))
                    .offset(x: x - 13)
            }
        }
    }

    private var trailCount: Int {
        switch effort {
        case .off: return 0
        case .low: return 4
        case .medium: return 8
        case .high: return 13
        case .max: return 20
        }
    }

    private var flowCount: Int {
        switch effort {
        case .off: return 0
        case .low: return 3
        case .medium: return 6
        case .high: return 10
        case .max: return 14
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
