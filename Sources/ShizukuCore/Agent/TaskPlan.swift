import Foundation

/// 任务状态,原始值与上游 `todowrite` / 前端保持一致。
public enum TaskStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
    case cancelled
}

/// 任务优先级。
public enum TaskPriority: String, Codable, Sendable, Equatable, CaseIterable {
    case high
    case medium
    case low
}

/// 会话任务计划中的一项。
public struct TaskItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var content: String
    public var status: TaskStatus
    public var priority: TaskPriority

    public init(
        id: UUID = UUID(),
        content: String,
        status: TaskStatus = .pending,
        priority: TaskPriority = .medium
    ) {
        self.id = id
        self.content = content
        self.status = status
        self.priority = priority
    }
}

/// 任务计划校验失败原因。
public enum TaskPlanError: Error, Sendable, Equatable {
    case tooManyItems(Int)
    case emptyContent
    case contentTooLong(Int)
    case multipleInProgress
    case missingTodos
    case invalidItem
    case runEnded
}

extension TaskPlanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tooManyItems(let count): return "任务列表最多 50 项,当前 \(count) 项"
        case .emptyContent: return "任务内容不能为空"
        case .contentTooLong(let count): return "任务内容过长(\(count) 字,上限 1000)"
        case .multipleInProgress: return "同一时间只能有一个正在执行的任务"
        case .missingTodos: return "缺少 todos 参数,且必须是数组"
        case .invalidItem: return "任务项格式无效"
        case .runEnded: return "本轮任务已经结束,无法更新任务计划"
        }
    }
}

/// 会话级任务计划,按 `(thread_id, persona)` 持久化。
/// `runID` 绑定当前这一轮 Agent 执行,防止上一轮的工具调用串写计划。
public struct TaskPlan: Codable, Sendable, Equatable {
    public var items: [TaskItem]
    public var running: Bool
    public var runID: String

    public init(items: [TaskItem] = [], running: Bool = false, runID: String = "") {
        self.items = items
        self.running = running
        self.runID = runID
    }

    public static let empty = TaskPlan()

    /// 校验并返回自身(顺序:数量 → 内容 → 并发状态)。
    @discardableResult
    public func validated() throws -> TaskPlan {
        guard items.count <= 50 else { throw TaskPlanError.tooManyItems(items.count) }
        for item in items {
            let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw TaskPlanError.emptyContent }
            guard trimmed.count <= 1000 else { throw TaskPlanError.contentTooLong(trimmed.count) }
        }
        guard items.filter({ $0.status == .inProgress }).count <= 1 else {
            throw TaskPlanError.multipleInProgress
        }
        return self
    }

    public var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }

    public var progressText: String {
        "\(completedCount)/\(items.count)"
    }

    /// 注入系统提示词的任务进度文本;空计划返回空串。
    public var promptText: String {
        guard !items.isEmpty else { return "" }
        let lines = items.map { "- [\($0.status.rawValue)] \($0.content)" }
        return "[当前会话任务进度]\n" + lines.joined(separator: "\n")
    }

    /// 工具结果中的可读列表。
    public var displayText: String {
        guard !items.isEmpty else { return "当前没有任务计划。" }
        return (["任务进度 \(progressText)"] + items.map { "- [\($0.status.rawValue)] \($0.content)" })
            .joined(separator: "\n")
    }
}
