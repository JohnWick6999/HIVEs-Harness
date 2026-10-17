import Foundation

/// 工作模式:决定工具可见性与文件访问边界。
/// - chat:只读(可读任意路径),适合问答/规划
/// - sandbox:可读任意路径,写入限制在工作区,禁止未隔离外部执行
/// - full:完全控制,外部写入与执行需用户审批
public enum WorkMode: String, Codable, Sendable, Equatable, CaseIterable {
    case chat
    case sandbox
    case full

    public var title: String {
        switch self {
        case .chat: return "对话"
        case .sandbox: return "安全"
        case .full: return "完全控制"
        }
    }

    public var detail: String {
        switch self {
        case .chat:
            return "只读:可列目录、读取任意本地路径,禁止写文件与执行外部代码。"
        case .sandbox:
            return "安全:可读任意本地路径,只能写工作区,禁止未隔离的外部代码执行。"
        case .full:
            return "完全控制:可写工作区外文件、执行本机 Agent,外部写入与执行会请求审批。"
        }
    }

    /// 当前模式是否允许某个工具出现在模型工具列表中(执行阶段还会再校验一次)。
    public func allows(tool name: String) -> Bool {
        // MCP 远程工具统一视为外部执行,只有完全控制模式可用
        if name.hasPrefix("mcp__") { return self == .full }
        switch self {
        case .chat:
            return Self.readOnlyTools.contains(name)
        case .sandbox:
            return !Self.externalExecutionTools.contains(name)
        case .full:
            return true
        }
    }

    /// 该工具执行前是否需要用户审批。
    public static func requiresExecutionApproval(for name: String) -> Bool {
        externalExecutionTools.contains(name) || name.hasPrefix("mcp__")
    }

    /// 允许读取工作区外路径(三种模式一致,对齐上游行为)。
    public var allowsOutsideRead: Bool { true }

    /// 允许写工作区外路径(仅完全控制,且需要审批)。
    public var allowsOutsideWrite: Bool { self == .full }

    /// 需要单次审批的外部执行工具。
    public var requiresExecutionApproval: Bool { self == .full }

    public static let readOnlyTools: Set<String> = [
        "read_file", "list_dir", "search_memory", "add_memory", "todowrite", "todoread",
        "list_skills", "run_skill", "ask_user",
        "run_subagent", "run_subagent_cluster", "spawn_background_task",
    ]

    public static let externalExecutionTools: Set<String> = [
        "run_local_agent", "call_mcp", "shell", "http_get",
    ]
}

/// 审批类型。
public enum ApprovalKind: String, Codable, Sendable, Equatable {
    case externalWrite
    case toolExecution
    case auxiliaryModel
    case shell

    public var title: String {
        switch self {
        case .externalWrite: return "写入工作区外文件"
        case .toolExecution: return "执行外部工具"
        case .auxiliaryModel: return "调用辅助模型"
        case .shell: return "执行 Shell 命令"
        }
    }
}

/// 一次审批请求(展示给 UI)。
public struct ApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: ApprovalKind
    public let detail: String
    /// 去重主体:工具名 / 文件路径等。未提供时退回 detail。
    public let subject: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: ApprovalKind,
        detail: String,
        subject: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.detail = detail
        self.subject = subject
        self.createdAt = createdAt
    }

    /// “始终允许”去重键:同一工具/同一路径只问一次,与本次参数无关。
    public var key: String {
        let scope = (subject ?? detail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(kind.rawValue)|\(scope)"
    }
}

public enum ApprovalDecision: String, Sendable, Equatable {
    case once
    case always
    case reject
}

/// 审批回调:由平台壳实现(弹窗/生物认证),Core 只负责等待结果。
public typealias ApprovalHandler = @Sendable (ApprovalRequest) async -> ApprovalDecision
