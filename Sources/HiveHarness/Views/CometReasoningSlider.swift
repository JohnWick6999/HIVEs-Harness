import SwiftUI
import HiveHarnessCore

/// 粗粒度推理滑杆:统一档位坐标 + 能量轨道 + 左侧喷溅粒子。
struct CometReasoningSlider: View {
    @Binding var effort: ReasoningEffort
    private let levels = ReasoningEffort.allCases
    private let inset: CGFloat = 24

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                GeometryReader { geo in
                    let width = max(1, geo.size.width)
                    let usable = max(1, width - inset * 2)
                    let x = inset + fraction * usable

                    ZStack {
                        // 厚底座(与档位坐标共用 inset)
                        Capsule()
                            .fill(Color.primary.opacity(0.075))
                            .frame(width: usable, height: 16)
                            .overlay(
                                Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .position(x: width / 2, y: 28)

                        // 呼吸光晕,只覆盖已选区域
                        if effort != .off {
                            Capsule()
                                .fill(color.opacity(0.26 + 0.10 * sin(time * 2.1)))
                                .frame(width: max(0, x - inset), height: 28)
                                .blur(radius: 12)
                                .position(x: inset + max(0, x - inset) / 2, y: 28)
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
                            .frame(width: max(0, x - inset), height: 16)
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
                                        .offset(x: CGFloat((sin(time * 1.6) + 1) / 2) * max(0, x - inset - 46))
                                        .blendMode(.plusLighter)
                                }
                            }
                            .shadow(color: color.opacity(0.38), radius: 8)
                            .position(x: inset + max(0, x - inset) / 2, y: 28)

                        // 覆盖区域内的漂浮能量点
                        if effort != .off {
                            ForEach(0..<flowCount, id: \.self) { index in
                                let progress = (time * 0.16 + Double(index) / Double(max(1, flowCount)))
                                    .truncatingRemainder(dividingBy: 1)
                                Circle()
                                    .fill(color.opacity(0.65))
                                    .frame(width: 2.5, height: 2.5)
                                    .position(
                                        x: inset + CGFloat(progress) * max(0, x - inset),
                                        y: 28 + sin(time * 3.0 + Double(index) * 1.2) * 6
                                    )
                                    .blur(radius: 0.4)
                            }
                        }

                        // 左侧喷溅(等级越高,数量/距离/速度越大)
                        spray(x: x, time: time)

                        // 彗尾 + 滑块头
                        comet(x: x, time: time)

                        // 档位节点:与底部文字共用同一坐标
                        ForEach(levels.indices, id: \.self) { index in
                            Circle()
                                .fill(index <= effort.index ? color : Color.primary.opacity(0.2))
                                .frame(width: index == effort.index ? 10 : 6,
                                       height: index == effort.index ? 10 : 6)
                                .shadow(color: index == effort.index ? color.opacity(0.8) : .clear,
                                        radius: index == effort.index ? 7 : 0)
                                .position(x: inset + CGFloat(index) / CGFloat(max(1, levels.count - 1)) * usable,
                                          y: 28)
                        }
                    }
                    .frame(height: 56)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                update(value.location.x, width: width, usable: usable)
                            }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                update(value.location.x, width: width, usable: usable)
                            }
                    )
                }
            }
            .frame(height: 56)

            // 底部文字:使用与节点完全相同的 x 坐标
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let usable = max(1, width - inset * 2)
                ForEach(levels) { level in
                    Text(level.title)
                        .font(.system(size: 9, weight: level == effort ? .bold : .regular))
                        .foregroundStyle(level == effort ? color : Color.secondary)
                        .fixedSize()
                        .position(
                            x: max(16, min(width - 16,
                                inset + CGFloat(level.index) / CGFloat(max(1, levels.count - 1)) * usable)),
                            y: 8
                        )
                        .scaleEffect(level == effort ? 1.06 : 1)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: effort)
                }
            }
            .frame(height: 16)
        }
        .frame(height: 78)
    }

    private func update(_ locationX: CGFloat, width: CGFloat, usable: CGFloat) {
        let fraction = (locationX - inset) / max(1, usable)
        let index = Int((fraction * CGFloat(levels.count - 1)).rounded())
        let next = levels[min(levels.count - 1, max(0, index))]
        if next != effort { effort = next }
    }

    private var fraction: CGFloat {
        CGFloat(effort.index) / CGFloat(max(1, levels.count - 1))
    }

    @ViewBuilder
    private func spray(x: CGFloat, time: TimeInterval) -> some View {
        let count = sprayCount
        if count > 0 {
            ForEach(0..<count, id: \.self) { index in
                let phase = (time * 0.62 + Double(index) / Double(count))
                    .truncatingRemainder(dividingBy: 1)
                let distance = CGFloat(phase) * (18 + CGFloat(effort.index) * 8)
                let spread = sin(Double(index) * 2.31 + time * 1.4) * 11
                Circle()
                    .fill(color.opacity(max(0.05, 0.62 * (1 - phase))))
                    .frame(width: max(1.4, 4.5 - CGFloat(phase) * 2.2),
                           height: max(1.4, 4.5 - CGFloat(phase) * 2.2))
                    .blur(radius: phase > 0.55 ? 1.2 : 0.25)
                    .position(
                        x: max(0, x - 13 - distance),
                        y: 28 + spread
                    )
            }
        }
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
                    .position(
                        x: max(0, x - CGFloat(index + 1) * (effort == .max ? 4.8 : 5.8) + CGFloat(drift)),
                        y: 28 + CGFloat(drift * 0.7)
                    )
            }

            Circle()
                .fill(color.opacity(0.35))
                .frame(width: effort == .max ? 34 : 24,
                       height: effort == .max ? 34 : 24)
                .blur(radius: 9)
                .position(x: x, y: 28)

            Circle()
                .fill(.white)
                .overlay(Circle().fill(color.opacity(0.55)).padding(2))
                .frame(width: effort == .max ? 20 : 16,
                       height: effort == .max ? 20 : 16)
                .overlay(Circle().stroke(color.opacity(0.9), lineWidth: 1.2))
                .position(x: x, y: 28)
                .shadow(color: color.opacity(0.95), radius: effort == .max ? 12 : 7)

            if effort == .max {
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
                    .position(x: x, y: 28)
                    .opacity(0.85)

                ForEach(0..<10, id: \.self) { index in
                    let angle = time * 1.8 + Double(index) / 10 * .pi * 2
                    Circle()
                        .fill(index.isMultiple(of: 2) ? Color.pink : Color.cyan)
                        .frame(width: 3, height: 3)
                        .position(
                            x: x + CGFloat(cos(angle)) * 22,
                            y: 28 + CGFloat(sin(angle)) * 16
                        )
                        .shadow(color: .pink.opacity(0.8), radius: 4)
                }
            } else if effort == .high {
                Circle()
                    .stroke(color.opacity(0.45), lineWidth: 1)
                    .frame(width: 26, height: 26)
                    .scaleEffect(1 + 0.12 * sin(time * 3))
                    .position(x: x, y: 28)
            }
        }
    }

    private var sprayCount: Int {
        switch effort {
        case .off: return 0
        case .low: return 5
        case .medium: return 10
        case .high: return 16
        case .max: return 24
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
