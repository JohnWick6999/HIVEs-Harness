import SwiftUI
import HiveHarnessCore

/// 粗粒度推理滑杆:档位坐标统一;动效严格裁剪在已选区域内,粒子从左侧喷溅。
struct CometReasoningSlider: View {
    @Binding var effort: ReasoningEffort
    private let levels = ReasoningEffort.allCases
    /// 轨道左右留白;节点另留 10pt,保证首尾节点不超出轨道。
    private let trackInset: CGFloat = 24
    private let knobInset: CGFloat = 34

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                GeometryReader { geo in
                    let width = max(1, geo.size.width)
                    let trackWidth = max(1, width - trackInset * 2)
                    let knobWidth = max(1, width - knobInset * 2)
                    let x = knobInset + fraction * knobWidth
                    let activeWidth = max(0, x - trackInset)

                    ZStack {
                        // 轨道底座
                        Capsule()
                            .fill(Color.primary.opacity(0.075))
                            .frame(width: trackWidth, height: 16)
                            .overlay(
                                Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .position(x: width / 2, y: 28)

                        // 已选区域:整层裁剪,光晕/流光/粒子不会越过滑块头右侧
                        if activeWidth > 0 && effort != .off {
                            activeLayer(width: activeWidth, time: time)
                                .frame(width: activeWidth, height: 56, alignment: .leading)
                                .clipped()
                                .position(x: trackInset + activeWidth / 2, y: 28)
                        }

                        // 左侧喷溅
                        spray(x: x, time: time)

                        // 彗尾与滑块头
                        comet(x: x, time: time)

                        // 档位节点:首尾向内收,不再压出轨道
                        ForEach(levels.indices, id: \.self) { index in
                            Circle()
                                .fill(index <= effort.index ? color : Color.primary.opacity(0.2))
                                .frame(width: index == effort.index ? 10 : 6,
                                       height: index == effort.index ? 10 : 6)
                                .shadow(color: index == effort.index ? color.opacity(0.7) : .clear,
                                        radius: index == effort.index ? 5 : 0)
                                .position(
                                    x: knobInset + CGFloat(index) / CGFloat(max(1, levels.count - 1)) * knobWidth,
                                    y: 28
                                )
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

            // 标签与节点共用同一坐标
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let knobWidth = max(1, width - knobInset * 2)
                ForEach(levels) { level in
                    Text(level.title)
                        .font(.system(size: 9, weight: level == effort ? .bold : .regular))
                        .foregroundStyle(level == effort ? color : Color.secondary)
                        .fixedSize()
                        .position(
                            x: max(16, min(width - 16,
                                knobInset + CGFloat(level.index) / CGFloat(max(1, levels.count - 1)) * knobWidth)),
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

    /// 只在 activeWidth 内绘制:呼吸光晕、能量轨道、流光、内部粒子。
    @ViewBuilder
    private func activeLayer(width: CGFloat, time: TimeInterval) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(color.opacity(0.22 + 0.09 * sin(time * 2.1)))
                .frame(width: width, height: 28)
                .blur(radius: 10)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.48), color, color.opacity(0.82)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: width, height: 16)
                .overlay {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.42), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 42)
                        .offset(x: CGFloat((sin(time * 1.6) + 1) / 2) * max(0, width - 42))
                        .blendMode(.plusLighter)
                }

            ForEach(0..<flowCount, id: \.self) { index in
                let progress = (time * 0.16 + Double(index) / Double(max(1, flowCount)))
                    .truncatingRemainder(dividingBy: 1)
                Circle()
                    .fill(color.opacity(0.65))
                    .frame(width: 2.5, height: 2.5)
                    .position(
                        x: CGFloat(progress) * width,
                        y: 28 + sin(time * 3.0 + Double(index) * 1.2) * 6
                    )
                    .blur(radius: 0.4)
            }
        }
        .frame(width: width, height: 56, alignment: .leading)
        .clipped()
    }

    private func update(_ locationX: CGFloat, width: CGFloat) {
        let knobWidth = max(1, width - knobInset * 2)
        let fraction = (locationX - knobInset) / knobWidth
        let index = Int((fraction * CGFloat(levels.count - 1)).rounded())
        let next = levels[min(levels.count - 1, max(0, index))]
        if next != effort { effort = next }
    }

    private var fraction: CGFloat {
        CGFloat(effort.index) / CGFloat(max(1, levels.count - 1))
    }

    /// 从滑块头向左喷溅;位置始终在 x 左侧,不会跑到右边。
    @ViewBuilder
    private func spray(x: CGFloat, time: TimeInterval) -> some View {
        let count = sprayCount
        if count > 0 {
            ForEach(0..<count, id: \.self) { index in
                let phase = (time * 0.62 + Double(index) / Double(count))
                    .truncatingRemainder(dividingBy: 1)
                let distance = CGFloat(phase) * (16 + CGFloat(effort.index) * 8)
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

    /// 彗尾只向左;不再绘制高级等级环/环绕粒子。
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
                .fill(color.opacity(0.30))
                .frame(width: effort == .max ? 28 : 20,
                       height: effort == .max ? 28 : 20)
                .blur(radius: 8)
                .position(x: x, y: 28)

            Circle()
                .fill(.white)
                .overlay(Circle().fill(color.opacity(0.55)).padding(2))
                .frame(width: effort == .max ? 20 : 16,
                       height: effort == .max ? 20 : 16)
                .overlay(Circle().stroke(color.opacity(0.9), lineWidth: 1.2))
                .position(x: x, y: 28)
                .shadow(color: color.opacity(0.8), radius: effort == .max ? 7 : 4)
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
