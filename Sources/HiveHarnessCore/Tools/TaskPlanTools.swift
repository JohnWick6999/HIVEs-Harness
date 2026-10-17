import Foundation

/// 任务计划工具:`todowrite` / `todoread`。
/// 计划按 `(thread_id, persona)` 持久化,写入绑定当前运行的 `runID`,
/// 防止上一轮的模型调用在下一轮里篡改计划。
public enum TaskPlanTools {
    // MARK: - todowrite

    public struct TodoWriteTool: Tool {
        public let name = "todowrite"
        public let spec = ToolSpec(
            name: "todowrite",
            description: "Create or replace the full session task plan for multi-step work. Keep exactly one task in_progress, update after each meaningful step, and mark completed only after verification. Do not create a plan for simple conversation.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "todos": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "content": ["type": "string"],
                                "status": [
                                    "type": "string",
                                    "enum": ["pending", "in_progress", "completed", "cancelled"],
                                ],
                                "priority": [
                                    "type": "string",
                                    "enum": ["high", "medium", "low"],
                                ],
                            ],
                            "required": ["content", "status", "priority"],
                        ],
                    ],
                ]),
                "required": AnyCodable(["todos"]),
            ]
        )

        private let store: SQLiteStore
        private let threadID: String
        private let persona: String
        private let runID: String

        public init(store: SQLiteStore, threadID: String, persona: String, runID: String) {
            self.store = store
            self.threadID = threadID
            self.persona = persona
            self.runID = runID
        }

        public func run(arguments: [String: AnyCodable]) throws -> ToolResult {
            guard let rawItems = arguments["todos"]?.value as? [Any] else {
                throw TaskPlanError.missingTodos
            }
            let items = try rawItems.map(Self.parseItem)

            var plan = try store.loadTaskPlan(threadID: threadID, persona: persona)
            guard plan.running, plan.runID == runID else {
                throw TaskPlanError.runEnded
            }
            plan.items = items
            try plan.validated()
            try store.saveTaskPlan(plan, threadID: threadID, persona: persona)
            return ToolResult(text: plan.displayText)
        }

        private static func parseItem(_ raw: Any) throws -> TaskItem {
            guard let dict = raw as? [String: Any] else { throw TaskPlanError.invalidItem }
            let content = (dict["content"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw TaskPlanError.emptyContent }
            guard content.count <= 1000 else { throw TaskPlanError.contentTooLong(content.count) }
            guard let statusRaw = dict["status"] as? String,
                  let status = TaskStatus(rawValue: statusRaw)
            else { throw TaskPlanError.invalidItem }
            let priorityRaw = dict["priority"] as? String ?? TaskPriority.medium.rawValue
            guard let priority = TaskPriority(rawValue: priorityRaw) else {
                throw TaskPlanError.invalidItem
            }
            return TaskItem(content: content, status: status, priority: priority)
        }
    }

    // MARK: - todoread

    public struct TodoReadTool: Tool {
        public let name = "todoread"
        public let spec = ToolSpec(
            name: "todoread",
            description: "Read the current session task plan.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([:]),
            ]
        )

        private let store: SQLiteStore
        private let threadID: String
        private let persona: String

        public init(store: SQLiteStore, threadID: String, persona: String) {
            self.store = store
            self.threadID = threadID
            self.persona = persona
        }

        public func run(arguments: [String: AnyCodable]) throws -> ToolResult {
            let plan = try store.loadTaskPlan(threadID: threadID, persona: persona)
            return ToolResult(text: plan.displayText)
        }
    }
}
