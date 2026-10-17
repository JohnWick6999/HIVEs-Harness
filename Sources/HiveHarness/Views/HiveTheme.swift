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

    // 外观偏好(全部走 AppStorage,主窗口与设置实时联动)
    static let appearanceKey = "appearanceTheme"
    static let glassIntensityKey = "glassIntensity"
    static let sidebarWidthKey = "sidebarWidth"
    static let showUsageBarKey = "showTokenUsageBar"
    static let defaultGlassIntensity = 0.55
    static let defaultSidebarWidth = 240.0
}

enum HiveAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 柔和背景:窗口底色 + 左上暖光 + 右下冷光。
struct HiveBackground: View {
    @AppStorage(HiveTheme.glassIntensityKey) private var glassIntensity = HiveTheme.defaultGlassIntensity
    @Environment(\.colorScheme) private var colorScheme

    private var aurora: Double {
        let base = 0.55 + min(1, max(0, glassIntensity)) * 0.9
        return colorScheme == .dark ? base * 0.52 : base
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [HiveTheme.honey.opacity(0.13 * aurora), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 620
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.075 * aurora), .clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 720
            )
            RadialGradient(
                colors: [HiveTheme.amber.opacity(0.10 * aurora), .clear],
                center: .topTrailing,
                startRadius: 30,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color.cyan.opacity(0.05 * aurora), .clear],
                center: .bottomLeading,
                startRadius: 80,
                endRadius: 460
            )
            LinearGradient(
                colors: [.white.opacity(colorScheme == .dark ? 0.018 : 0.035), .clear, .black.opacity(0.025)],
                startPoint: .top,
                endPoint: .bottom
            )
            if colorScheme == .dark {
                Color.black.opacity(0.08)
            }
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
            .hiveGlass(corner: corner)
    }
}

/// Apple Liquid Glass(macOS 26+);旧系统回退为材质 + 高光/边缘折射。
struct HiveGlassModifier: ViewModifier {
    var corner: CGFloat
    var tint: Color?
    var interactive: Bool

    @AppStorage(HiveTheme.glassIntensityKey) private var glassIntensity = HiveTheme.defaultGlassIntensity
    @Environment(\.colorScheme) private var colorScheme

    private var strength: Double { min(1, max(0, glassIntensity)) }
    private var isDark: Bool { colorScheme == .dark }
    /// 深色下白色高光必须大幅衰减,否则正文对比度会被玻璃吃掉。
    private var whiteScale: Double { isDark ? 0.32 : 1.0 }
    private var darkBase: Double { isDark ? 0.14 + strength * 0.12 : 0 }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = {
                var value = Glass.regular
                if isDark {
                    value = value.tint(.black.opacity(0.18))
                } else if let tint {
                    value = value.tint(tint)
                }
                if interactive { value = value.interactive() }
                return value
            }()
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            content
                .background(Color.black.opacity(darkBase), in: shape)
                .glassEffect(glass, in: shape)
                .overlay {
                    ZStack {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity((0.05 + strength * 0.16) * whiteScale),
                                        .white.opacity(0.02 * whiteScale),
                                        HiveTheme.amber.opacity((0.02 + strength * 0.035) * (isDark ? 0.45 : 1)),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                        shape.stroke(
                            LinearGradient(
                                colors: [
                                    .white.opacity((0.16 + strength * 0.28) * whiteScale),
                                    .white.opacity(0.06 * whiteScale),
                                    .black.opacity(0.10),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                        .allowsHitTesting(false)
                        shape
                            .fill(Color.white.opacity((0.005 + strength * 0.035) * whiteScale))
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    }
                }
                .shadow(color: .black.opacity(0.06 + strength * 0.10), radius: 10 + strength * 12, y: 4 + strength * 4)
        } else {
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            content
                .background(.ultraThinMaterial, in: shape)
                .background(Color.black.opacity(darkBase), in: shape)
                .background(
                    LinearGradient(
                        colors: [
                            .white.opacity((0.04 + strength * 0.12) * whiteScale),
                            .clear,
                            HiveTheme.amber.opacity((0.025 + strength * 0.03) * (isDark ? 0.4 : 1)),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: shape
                )
                .overlay {
                    ZStack {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity((0.05 + strength * 0.14) * whiteScale),
                                        .clear,
                                        HiveTheme.amber.opacity((0.02 + strength * 0.03) * (isDark ? 0.4 : 1)),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .blendMode(.plusLighter)
                        shape.stroke(
                            LinearGradient(
                                colors: [
                                    .white.opacity((0.15 + strength * 0.30) * whiteScale),
                                    HiveTheme.hairline,
                                    .black.opacity(0.12 + strength * 0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                        shape
                            .fill(Color.white.opacity((0.004 + strength * 0.032) * whiteScale))
                            .blendMode(.plusLighter)
                    }
                }
                .shadow(color: .black.opacity(0.06 + strength * 0.12), radius: 12 + strength * 14, y: 4 + strength * 4)
        }
    }
}

extension View {
    func hiveCard(padding: CGFloat = 12, corner: CGFloat = HiveTheme.corner) -> some View {
        modifier(HiveCardModifier(padding: padding, corner: corner))
    }

    func hiveGlass(
        corner: CGFloat = HiveTheme.corner,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(HiveGlassModifier(corner: corner, tint: tint, interactive: interactive))
    }
}

/// 任务中途的澄清卡片:选项 + 推荐 + 自由补充 + 跳过。
struct HiveQuestionCard: View {
    let question: ClarificationRequest
    let onAnswer: (ClarificationAnswer) -> Void
    let onSkip: () -> Void

    @State private var index = 0
    @State private var selections: [Int: Set<String>]
    @State private var freeforms: [Int: String] = [:]

    init(
        question: ClarificationRequest,
        onAnswer: @escaping (ClarificationAnswer) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.question = question
        self.onAnswer = onAnswer
        self.onSkip = onSkip
        var initial: [Int: Set<String>] = [:]
        for (index, item) in question.questions.enumerated() {
            let recommended = item.options.filter(\.recommended).map(\.label)
            initial[index] = Set(
                item.allowsMultiple ? recommended : Array(recommended.prefix(1))
            )
        }
        _selections = State(initialValue: initial)
    }

    private var current: ClarificationQuestion {
        question.questions[min(index, max(0, question.questions.count - 1))]
    }

    private var isLast: Bool { index >= question.questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(HiveTheme.amber)
                Text("HIVE 需要你确认")
                    .font(.caption.weight(.semibold))
                if question.questions.count > 1 {
                    Text("\(index + 1)/\(question.questions.count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(HiveTheme.amber.opacity(0.14), in: Capsule())
                        .foregroundStyle(HiveTheme.amberDeep)
                }
                Spacer()
                Text("可跳过")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            ZStack(alignment: .topLeading) {
                questionBody(current)
                    .id(index)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: index)

            HStack(spacing: 8) {
                Button("跳过全部") { onSkip() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if index > 0 {
                    Button {
                        withAnimation { index -= 1 }
                    } label: {
                        Label("上一步", systemImage: "chevron.left")
                    }
                }

                if isLast {
                    Button("确认") { confirm() }
                        .buttonStyle(.borderedProminent)
                        .tint(HiveTheme.amberDeep)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        withAnimation { index += 1 }
                    } label: {
                        Label("下一步", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HiveTheme.amberDeep)
                    .keyboardShortcut(.defaultAction)
                }
            }

            if question.questions.count > 1 {
                HStack(spacing: 5) {
                    ForEach(Array(question.questions.enumerated()), id: \.offset) { dot, _ in
                        Capsule()
                            .fill(dot == index ? HiveTheme.amber : HiveTheme.hairline)
                            .frame(width: dot == index ? 16 : 6, height: 4)
                            .animation(.easeInOut(duration: 0.18), value: index)
                    }
                    Spacer()
                    Text("回答会在最后统一提交,可随时返回修改")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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

    @ViewBuilder
    private func questionBody(_ item: ClarificationQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.question)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .textSelection(.enabled)

            if !item.context.isEmpty {
                Text(item.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !item.options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(item.options) { option in
                        optionRow(option, item: item)
                    }
                }
            }

            if item.allowsFreeform {
                TextField("其他补充…(可只填这里)", text: freeformBinding(index), axis: .vertical)
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
        }
    }

    private func optionRow(_ option: ClarificationOption, item: ClarificationQuestion) -> some View {
        let selected = selections[index] ?? []
        let isSelected = selected.contains(option.label)
        return Button {
            var current = selections[index] ?? []
            if item.allowsMultiple {
                if isSelected { current.remove(option.label) } else { current.insert(option.label) }
            } else {
                current = [option.label]
            }
            selections[index] = current
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isSelected
                      ? (item.allowsMultiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (item.allowsMultiple ? "square" : "circle"))
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

    private func freeformBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { freeforms[index] ?? "" },
            set: { freeforms[index] = $0 }
        )
    }

    private func confirm() {
        let answers = question.questions.enumerated().map { offset, item in
            let selected = selections[offset] ?? []
            let freeform = (freeforms[offset] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ClarificationQuestionAnswer(
                selected: item.options.map(\.label).filter { selected.contains($0) },
                freeform: freeform.isEmpty ? nil : freeform
            )
        }
        onAnswer(ClarificationAnswer(answers: answers))
    }
}
