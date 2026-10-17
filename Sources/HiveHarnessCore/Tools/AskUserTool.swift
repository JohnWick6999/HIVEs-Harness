import Foundation

/// 让 Agent 在任务中途真正停下来向用户提问的工具。
/// 与普通工具不同,它会 await 平台壳注入的 ClarificationHandler,
/// 用户选择后再把答案回填给模型继续规划。
public struct AskUserTool: Tool {
    public let name = "ask_user"

    public let spec = ToolSpec(
        name: "ask_user",
        description: """
        Ask the user a clarifying question when missing information materially changes the plan. \
        Offer 2-4 concrete options, mark one as recommended when appropriate, and allow freeform input. \
        Do not ask for facts already present in the conversation or tools; do not use this to ask permission. \
        Maximum 2 questions per run.
        """,
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "question": [
                    "type": "string",
                    "description": "短而具体的问题,说明需要用户决定什么。",
                ],
                "context": [
                    "type": "string",
                    "description": "为什么问;不同选择会怎样影响方案。",
                ],
                "options": [
                    "type": "array",
                    "description": "2-4 个具体可执行选项;没有合适选项时可省略,让用户自由输入。",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string"],
                            "description": ["type": "string"],
                            "recommended": ["type": "boolean"],
                        ],
                        "required": ["label"],
                    ],
                ],
                "allow_multiple": [
                    "type": "boolean",
                    "description": "是否允许多选(默认 false)。",
                ],
                "allow_freeform": [
                    "type": "boolean",
                    "description": "是否允许用户自由补充(默认 true)。",
                ],
            ]),
            "required": AnyCodable(["question"]),
        ]
    )

    private let handler: ClarificationHandler?
    private let gate: ClarificationGate

    public init(
        handler: ClarificationHandler?,
        gate: ClarificationGate = ClarificationGate()
    ) {
        self.handler = handler
        self.gate = gate
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let question = (arguments["question"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            throw ToolError.invalidArguments("ask_user 需要非空的 question")
        }
        let context = (arguments["context"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowsMultiple = arguments["allow_multiple"]?.value as? Bool ?? false
        let allowsFreeform = arguments["allow_freeform"]?.value as? Bool ?? true

        var options: [ClarificationOption] = []
        if let rawOptions = arguments["options"]?.value as? [Any] {
            for raw in rawOptions {
                guard let dict = raw as? [String: Any],
                      let label = (dict["label"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.isEmpty
                else { continue }
                options.append(
                    ClarificationOption(
                        label: label,
                        description: dict["description"] as? String ?? "",
                        recommended: dict["recommended"] as? Bool ?? false
                    )
                )
            }
        }
        guard !options.isEmpty || allowsFreeform else {
            throw ToolError.invalidArguments("ask_user 至少需要一个选项,或允许自由输入")
        }

        guard await gate.shouldAsk(question) else {
            return ToolResult(
                text: "本轮提问预算已用完(或问题重复)。不要再次调用 ask_user;请根据现有信息选择最保守、可逆的方案继续,并在回复中说明假设。"
            )
        }

        guard let handler else {
            return ToolResult(
                text: "当前没有可用的用户交互通道。请基于现有信息继续,并明确说明你的假设,不要再次提问。"
            )
        }

        let request = ClarificationRequest(
            question: question,
            context: context,
            options: options,
            allowsMultiple: allowsMultiple,
            allowsFreeform: allowsFreeform
        )
        let answer = await handler(request)

        if answer.cancelled {
            return ToolResult(
                text: "用户跳过了这个问题。请采用最保守、可逆的默认方案继续,并在回复中说明你的假设,不要重复提问。"
            )
        }

        var lines: [String] = []
        if !answer.selected.isEmpty {
            lines.append("用户选择: " + answer.selected.joined(separator: "、"))
        }
        if let freeform = answer.freeform?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !freeform.isEmpty {
            lines.append("用户补充: \(freeform)")
        }
        guard !lines.isEmpty else {
            return ToolResult(text: "用户未提供选择。请基于现有信息继续,并说明假设。")
        }
        return ToolResult(
            text: lines.joined(separator: "\n") + "\n请据此继续推进;除非出现新的关键歧义,不要重复提问。"
        )
    }
}
