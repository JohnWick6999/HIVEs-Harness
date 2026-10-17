import SwiftUI
import HiveHarnessCore

/// 选择推理档位时的一次性高级动效:等级越高,光环/粒子越多。
struct ReasoningBurstView: View {
    let effort: ReasoningEffort
    @State private var animate = false

    private var color: Color {
        switch effort {
        case .off: return .secondary
        case .low: return .cyan
        case .medium: return HiveTheme.amber
        case .high: return .orange
        case .max: return .pink
        }
    }

    private var ringCount: Int {
        switch effort {
        case .off: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 2
        case .max: return 3
        }
    }

    private var sparkCount: Int {
        switch effort {
        case .off: return 0
        case .low: return 0
        case .medium: return 5
        case .high: return 12
        case .max: return 20
        }
    }

    private var label: String {
        switch effort {
        case .off: return "快速回答"
        case .low: return "轻度推理"
        case .medium: return "标准推理"
        case .high: return "深度推理"
        case .max: return "极致推理"
        }
    }

    var body: some View {
        ZStack {
            if effort != .off {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color.opacity(0.32), color.opacity(0.08), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 72
                        )
                    )
                    .frame(width: 150, height: 150)
                    .scaleEffect(animate ? 1.25 : 0.45)
                    .opacity(animate ? 0 : 0.95)

                ForEach(0..<ringCount, id: \.self) { ring in
                    Circle()
                        .stroke(
                            color.opacity(0.55 - Double(ring) * 0.12),
                            lineWidth: effort == .max ? 1.6 : 1
                        )
                        .frame(width: 44 + CGFloat(ring) * 18, height: 44 + CGFloat(ring) * 18)
                        .scaleEffect(animate ? 1.5 : 0.6)
                        .opacity(animate ? 0 : 1)
                        .animation(
                            .easeOut(duration: 0.9 + Double(ring) * 0.22)
                            .delay(Double(ring) * 0.06),
                            value: animate
                        )
                }

                if effort == .max {
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.pink, .purple, .cyan, .pink],
                                center: .center
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 92, height: 92)
                        .rotationEffect(.degrees(animate ? 160 : -20))
                        .scaleEffect(animate ? 1.35 : 0.8)
                        .opacity(animate ? 0 : 0.9)
                }

                ForEach(0..<sparkCount, id: \.self) { index in
                    let angle = Double(index) / Double(max(1, sparkCount)) * .pi * 2
                    Circle()
                        .fill(color)
                        .frame(width: effort == .max ? 3 : 2, height: effort == .max ? 3 : 2)
                        .offset(
                            x: CGFloat(cos(angle)) * (animate ? 62 : 12),
                            y: CGFloat(sin(angle)) * (animate ? 62 : 12)
                        )
                        .opacity(animate ? 0 : 0.9)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: effort == .max ? "flame.fill" : "brain.head.profile")
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.8))
            .scaleEffect(animate ? 1 : 0.8)
            .opacity(animate ? 0.95 : 1)
        }
        .frame(width: 190, height: 100)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 1.25)) {
                animate = true
            }
        }
    }
}
