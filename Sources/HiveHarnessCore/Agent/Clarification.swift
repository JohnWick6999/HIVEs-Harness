import Foundation

/// 用户在任务中途可选择的澄清选项。
public struct ClarificationOption: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public var label: String
    public var description: String
    /// 推荐项:UI 高亮,跳过时模型优先采用。
    public var recommended: Bool

    public init(label: String, description: String = "", recommended: Bool = false) {
        self.label = label
        self.description = description
        self.recommended = recommended
    }
}

/// Agent 主动向用户发起的澄清请求。
public struct ClarificationRequest: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var question: String
    /// 为什么需要这个信息 / 不同选择的影响。
    public var context: String
    public var options: [ClarificationOption]
    public var allowsMultiple: Bool
    public var allowsFreeform: Bool

    public init(
        id: UUID = UUID(),
        question: String,
        context: String = "",
        options: [ClarificationOption] = [],
        allowsMultiple: Bool = false,
        allowsFreeform: Bool = true
    ) {
        self.id = id
        self.question = question
        self.context = context
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.allowsFreeform = allowsFreeform
    }
}

/// 用户回答:选项 + 自由补充;cancel 表示跳过。
public struct ClarificationAnswer: Sendable, Equatable {
    public var selected: [String]
    public var freeform: String?
    public var cancelled: Bool

    public init(selected: [String] = [], freeform: String? = nil, cancelled: Bool = false) {
        self.selected = selected
        self.freeform = freeform
        self.cancelled = cancelled
    }

    public static let cancelled = ClarificationAnswer(cancelled: true)
}

public typealias ClarificationHandler = @Sendable (ClarificationRequest) async -> ClarificationAnswer

/// 主动提问偏好:关闭 / 平衡 / 积极。
public enum ClarificationMode: String, Codable, Sendable, CaseIterable, Equatable {
    case off
    case balanced
    case eager

    public var title: String {
        switch self {
        case .off: return "关闭"
        case .balanced: return "平衡"
        case .eager: return "积极"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return "不主动提问;遇到歧义时自行选择可逆的默认方案。"
        case .balanced:
            return "只在关键歧义处提问,每轮最多 2 个;先尝试推断。"
        case .eager:
            return "更主动确认方向,每轮最多 4 个;仍会先尝试从上下文推断。"
        }
    }

    public var maxQuestions: Int {
        switch self {
        case .off: return 0
        case .balanced: return 2
        case .eager: return 4
        }
    }
}

/// 每轮运行的提问预算与查重,避免“问题轰炸”。
public actor ClarificationGate {
    private let maxQuestions: Int
    private var asked = 0
    private var normalized = Set<String>()

    public init(maxQuestions: Int = 2) {
        self.maxQuestions = maxQuestions
    }

    /// 返回 false 表示本轮不应再问(预算耗尽或重复问题)。
    public func shouldAsk(_ question: String) -> Bool {
        guard asked < maxQuestions else { return false }
        let key = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty, !normalized.contains(key) else { return false }
        asked += 1
        normalized.insert(key)
        return true
    }

    public var remaining: Int { max(0, maxQuestions - asked) }
}
