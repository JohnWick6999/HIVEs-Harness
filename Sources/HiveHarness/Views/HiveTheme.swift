import AppKit
import SwiftUI
import HiveHarnessCore

/// HIVE's Harness 视觉系统:暖琥珀 + 石墨,轻材质、低噪点。
enum HiveTheme {
    static let amber = Color(red: 0.95, green: 0.62, blue: 0.15)
    static let honey = Color(red: 1.0, green: 0.80, blue: 0.36)
    static let amberDeep = Color(red: 0.78, green: 0.42, blue: 0.08)
    static let gradient = LinearGradient(
        colors: [honey, amber, amberDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let softGradient = LinearGradient(
        colors: [honey.opacity(0.22), amber.opacity(0.12)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let assistantBubble = Color.primary.opacity(0.055)
    static let userBubble = Color(red: 0.96, green: 0.70, blue: 0.26).opacity(0.18)
    static let hairline = Color.primary.opacity(0.07)
    static let card = Color.primary.opacity(0.035)
    static let corner: CGFloat = 16
    static let composerCorner: CGFloat = 18
}

/// 柔和背景:窗口底色 + 左上暖光 + 右下冷光。
struct HiveBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [HiveTheme.honey.opacity(0.10), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.055), .clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 720
            )
        }
        .ignoresSafeArea()
    }
}

/// 六边形蜂巢标记 + H。
struct HiveMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Image(systemName: "hexagon.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(HiveTheme.gradient)
                .shadow(color: HiveTheme.amber.opacity(0.35), radius: size * 0.18, y: size * 0.06)
            Text("H")
                .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
        .frame(width: size, height: size)
    }
}

/// 通用玻璃卡片。
struct HiveCardModifier: ViewModifier {
    var padding: CGFloat = 12
    var corner: CGFloat = HiveTheme.corner

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(HiveTheme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func hiveCard(padding: CGFloat = 12, corner: CGFloat = HiveTheme.corner) -> some View {
        modifier(HiveCardModifier(padding: padding, corner: corner))
    }
}

/// 任务中途的澄清卡片:选项 + 推荐 + 自由补充 + 跳过。
struct HiveQuestionCard: View {
    let question: ClarificationRequest
    let onAnswer: (ClarificationAnswer) -> Void
    let onSkip: () -> Void

    @State private var selected: Set<String> = []
    @State private var freeform = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(HiveTheme.amber)
                Text("HIVE 需要你确认")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("可跳过")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(question.question)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .textSelection(.enabled)

            if !question.context.isEmpty {
                Text(question.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !question.options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(question.options) { option in
                        optionRow(option)
                    }
                }
            }

            if question.allowsFreeform {
                TextField("其他补充…(可只填这里)", text: $freeform, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(HiveTheme.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(HiveTheme.hairline, lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                Button("跳过") { onSkip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("确认") {
                    onAnswer(
                        ClarificationAnswer(
                            selected: question.options
                                .map(\.label)
                                .filter { selected.contains($0) },
                            freeform: freeform.trimmingCharacters(in: .whitespacesAndNewlines),
                            cancelled: false
                        )
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(HiveTheme.amberDeep)
                .disabled(selected.isEmpty && freeform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(maxWidth: 780)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            HiveTheme.amber.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(HiveTheme.amber.opacity(0.34), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 20, y: 7)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func optionRow(_ option: ClarificationOption) -> some View {
        let isSelected = selected.contains(option.label)
        return Button {
            if question.allowsMultiple {
                if isSelected { selected.remove(option.label) } else { selected.insert(option.label) }
            } else {
                selected = [option.label]
            }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isSelected
                      ? (question.allowsMultiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (question.allowsMultiple ? "square" : "circle"))
                    .foregroundStyle(isSelected ? HiveTheme.amberDeep : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.callout.weight(.medium))
                        if option.recommended {
                            Text("推荐")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(HiveTheme.amber.opacity(0.18), in: Capsule())
                                .foregroundStyle(HiveTheme.amberDeep)
                        }
                    }
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(9)
            .background(
                isSelected ? HiveTheme.amber.opacity(0.12) : HiveTheme.card,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
