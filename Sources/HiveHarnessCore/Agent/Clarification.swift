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

/// 一个独立问题(支持多问题向导)。
public struct ClarificationQuestion: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var question: String
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

/// Agent 主动向用户发起的一组澄清问题。
public struct ClarificationRequest: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var questions: [ClarificationQuestion]

    public init(id: UUID = UUID(), questions: [ClarificationQuestion]) {
        self.id = id
        self.questions = questions
    }

    /// 单问题便捷构造(保持既有调用方兼容)。
    public init(
        id: UUID = UUID(),
        question: String,
        context: String = "",
        options: [ClarificationOption] = [],
        allowsMultiple: Bool = false,
        allowsFreeform: Bool = true
    ) {
        self.id = id
        self.questions = [
            ClarificationQuestion(
                question: question,
                context: context,
                options: options,
                allowsMultiple: allowsMultiple,
                allowsFreeform: allowsFreeform
            ),
        ]
    }

    public var question: String { questions.first?.question ?? "" }
    public var context: String { questions.first?.context ?? "" }
    public var options: [ClarificationOption] { questions.first?.options ?? [] }
    public var allowsMultiple: Bool { questions.first?.allowsMultiple ?? false }
    public var allowsFreeform: Bool { questions.first?.allowsFreeform ?? true }
}

/// 单个问题的回答。
public struct ClarificationQuestionAnswer: Sendable, Equatable {
    public var selected: [String]
    public var freeform: String?

    public init(selected: [String] = [], freeform: String? = nil) {
        self.selected = selected
        self.freeform = freeform
    }
}

/// 用户回答:逐题选项 + 自由补充;cancel 表示整组跳过。
public struct ClarificationAnswer: Sendable, Equatable {
    public var answers: [ClarificationQuestionAnswer]
    public var cancelled: Bool

    public init(answers: [ClarificationQuestionAnswer] = [], cancelled: Bool = false) {
        self.answers = answers
        self.cancelled = cancelled
    }

    /// 单问题便捷构造。
    public init(selected: [String] = [], freeform: String? = nil, cancelled: Bool = false) {
        self.answers = cancelled ? [] : [ClarificationQuestionAnswer(selected: selected, freeform: freeform)]
        self.cancelled = cancelled
    }

    /// 兼容旧代码:第一题的选项/补充。
    public var selected: [String] { answers.first?.selected ?? [] }
    public var freeform: String? { answers.first?.freeform }

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
        shouldAsk(questions: [question])
    }

    /// 批量提问:整组通过才计入预算,任一重复/超预算则整组拒绝。
    public func shouldAsk(questions: [String]) -> Bool {
        let keys = questions.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard !keys.isEmpty,
              !keys.contains(where: \.isEmpty),
              asked + keys.count <= maxQuestions,
              Set(keys).count == keys.count,
              normalized.isDisjoint(with: keys)
        else { return false }
        asked += keys.count
        normalized.formUnion(keys)
        return true
    }

    public var remaining: Int { max(0, maxQuestions - asked) }
}
