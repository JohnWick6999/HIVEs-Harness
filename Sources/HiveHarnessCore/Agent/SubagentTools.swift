import Foundation

public struct SubagentRequest: Sendable, Equatable {
    public var title: String
    public var role: String
    public var prompt: String

    public init(title: String, role: String = "", prompt: String) {
        self.title = title
        self.role = role
        self.prompt = prompt
    }
}

public struct SubagentResult: Sendable, Equatable {
    public var title: String
    public var reply: String
    public var success: Bool
    public var durationMs: Int

    public init(title: String, reply: String, success: Bool, durationMs: Int = 0) {
        self.title = title
        self.reply = reply
        self.success = success
        self.durationMs = durationMs
    }
}

public typealias SubagentRunner = @Sendable (SubagentRequest) async -> SubagentResult
public typealias AgentBackgroundTaskSpawner = @Sendable (String, String) async -> String

public enum AgentBackgroundTaskStatus: String, Codable, Sendable, Equatable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    public var title: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "运行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

public struct AgentBackgroundTask: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var prompt: String
    public var status: AgentBackgroundTaskStatus
    public var result: String?
    public var error: String?
    public var createdAt: Date
    public var finishedAt: Date?

    public init(
        id: String = "bg_" + UUID().uuidString.lowercased().prefix(8),
        title: String,
        prompt: String,
        status: AgentBackgroundTaskStatus = .running,
        result: String? = nil,
        error: String? = nil,
        createdAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.status = status
        self.result = result
        self.error = error
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

/// 运行一个独立子代理(只读上下文,结果返回给主 Agent)。
public struct RunSubagentTool: Tool {
    public let name = "run_subagent"
    public let spec = ToolSpec(
        name: "run_subagent",
        description: """
        Run an independent read-only subagent for research, review, or a focused subtask. \
        The subagent has its own context and no external execution tools. Use it when separating \
        concerns or parallel work would improve the answer; summarize its result yourself.
        """,
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "title": ["type": "string", "description": "任务短标题"],
                "role": ["type": "string", "description": "子代理角色,例如 code reviewer / researcher"],
                "prompt": ["type": "string", "description": "交给子代理的完整任务"],
            ]),
            "required": AnyCodable(["title", "prompt"]),
        ]
    )

    private let runner: SubagentRunner

    public init(runner: @escaping SubagentRunner) {
        self.runner = runner
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let title = (arguments["title"]?.value as? String ?? "子任务")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let role = arguments["role"]?.value as? String ?? ""
        let prompt = (arguments["prompt"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ToolError.invalidArguments("run_subagent 需要 prompt")
        }
        let result = await runner(SubagentRequest(title: title, role: role, prompt: prompt))
        let prefix = result.success ? "子代理完成" : "子代理失败"
        return ToolResult(
            text: "\(prefix): \(result.title)\n\n\(result.reply)"
        )
    }
}

/// 并行运行 2-4 个子代理。
public struct RunSubagentClusterTool: Tool {
    public let name = "run_subagent_cluster"
    public let spec = ToolSpec(
        name: "run_subagent_cluster",
        description: """
        Run 2-4 independent read-only subagents concurrently and return all results. \
        Use for parallel research, multiple review perspectives, or comparing approaches.
        """,
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "tasks": [
                    "type": "array",
                    "minItems": 2,
                    "maxItems": 4,
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "role": ["type": "string"],
                            "prompt": ["type": "string"],
                        ],
                        "required": ["title", "prompt"],
                    ],
                ],
            ]),
            "required": AnyCodable(["tasks"]),
        ]
    )

    private let runner: SubagentRunner

    public init(runner: @escaping SubagentRunner) {
        self.runner = runner
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let raw = arguments["tasks"]?.value as? [Any] else {
            throw ToolError.invalidArguments("run_subagent_cluster 需要 tasks 数组")
        }
        let requests: [SubagentRequest] = raw.prefix(4).compactMap { item in
            guard let dict = item as? [String: Any],
                  let title = dict["title"] as? String,
                  let prompt = dict["prompt"] as? String,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return SubagentRequest(
                title: title,
                role: dict["role"] as? String ?? "",
                prompt: prompt
            )
        }
        guard requests.count >= 2 else {
            throw ToolError.invalidArguments("集群至少需要 2 个有效任务")
        }

        let results = await withTaskGroup(of: SubagentResult.self) { group in
            for request in requests {
                group.addTask { await runner(request) }
            }
            var collected: [SubagentResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let text = results.map { result in
            let status = result.success ? "✅" : "❌"
            return "\(status) \(result.title)\n\(result.reply)"
        }.joined(separator: "\n\n---\n\n")
        return ToolResult(text: text)
    }
}

/// 启动后台任务,立即返回任务 id。
public struct SpawnAgentBackgroundTaskTool: Tool {
    public let name = "spawn_background_task"
    public let spec = ToolSpec(
        name: "spawn_background_task",
        description: """
        Start a read-only task in the background and return immediately with a task id. \
        Use for long research or review jobs. Do not poll; tell the user the task is running \
        and they can inspect it in Background Tasks.
        """,
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "title": ["type": "string"],
                "prompt": ["type": "string"],
            ]),
            "required": AnyCodable(["title", "prompt"]),
        ]
    )

    private let spawner: AgentBackgroundTaskSpawner

    public init(spawner: @escaping AgentBackgroundTaskSpawner) {
        self.spawner = spawner
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let title = (arguments["title"]?.value as? String ?? "后台任务")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = (arguments["prompt"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ToolError.invalidArguments("spawn_background_task 需要 prompt")
        }
        let id = await spawner(title, prompt)
        return ToolResult(text: "后台任务已创建: \(id)\n用户可在侧边栏「后台任务」查看进度,不要轮询等待。")
    }
}
