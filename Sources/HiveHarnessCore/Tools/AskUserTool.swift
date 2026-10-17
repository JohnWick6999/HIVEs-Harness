import Foundation

/// 让 Agent 在任务中途真正停下来向用户提问的工具。
/// 支持一次提交多个问题,UI 会以向导形式让用户前后切换并保留选择。
public struct AskUserTool: Tool {
    public let name = "ask_user"

    public let spec = ToolSpec(
        name: "ask_user",
        description: """
        Ask the user clarifying questions when missing information materially changes the plan. \
        Prefer batching related questions in one call via the questions array (1-4 items); the UI \
        lets the user go back, change answers, and submit once. Offer concrete options, mark one \
        recommended when appropriate, and allow freeform input. Do not ask for facts already present \
        in the conversation or tools; do not use this to ask permission.
        """,
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "question": [
                    "type": "string",
                    "description": "单问题快捷字段;与 questions 二选一。",
                ],
                "context": [
                    "type": "string",
                    "description": "为什么问;不同选择会怎样影响方案。",
                ],
                "options": [
                    "type": "array",
                    "description": "单问题选项;与 questions 二选一。",
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
                "questions": [
                    "type": "array",
                    "description": "一次提交的多个问题(建议 2-4 个)。",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string"],
                            "context": ["type": "string"],
                            "options": [
                                "type": "array",
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
                            "allow_multiple": ["type": "boolean"],
                            "allow_freeform": ["type": "boolean"],
                        ],
                        "required": ["question"],
                    ],
                ],
                "allow_multiple": ["type": "boolean"],
                "allow_freeform": ["type": "boolean"],
            ]),
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
        let questions = Self.parseQuestions(arguments)
        guard !questions.isEmpty else {
            throw ToolError.invalidArguments("ask_user 需要至少一个非空 question")
        }
        guard questions.count <= 4 else {
            return ToolResult(text: "一次最多提交 4 个问题;请拆成多次或先自行推断。")
        }
        for question in questions where question.options.isEmpty && !question.allowsFreeform {
            throw ToolError.invalidArguments("每个问题至少需要一个选项,或允许自由输入")
        }

        guard await gate.shouldAsk(questions: questions.map(\.question)) else {
            return ToolResult(
                text: "本轮提问预算已用完(或问题重复)。不要再次调用 ask_user;请根据现有信息选择最保守、可逆的方案继续,并在回复中说明假设。"
            )
        }

        guard let handler else {
            return ToolResult(
                text: "当前没有可用的用户交互通道。请基于现有信息继续,并明确说明你的假设,不要再次提问。"
            )
        }

        let answer = await handler(ClarificationRequest(questions: questions))
        if answer.cancelled {
            let subject = questions.count > 1 ? "这些问题" : "这个问题"
            return ToolResult(
                text: "用户跳过了\(subject)。请采用最保守、可逆的默认方案继续,并在回复中说明你的假设,不要重复提问。"
            )
        }

        var lines: [String] = []
        for (index, question) in questions.enumerated() {
            let item = index < answer.answers.count ? answer.answers[index] : nil
            let selected = item?.selected ?? []
            let freeform = (item?.freeform ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if questions.count > 1 {
                lines.append("问题 \(index + 1): \(question.question)")
            }
            if !selected.isEmpty {
                lines.append("用户选择: " + selected.joined(separator: "、"))
            }
            if !freeform.isEmpty {
                lines.append("用户补充: \(freeform)")
            }
            if selected.isEmpty, freeform.isEmpty {
                lines.append("用户未提供选择。")
            }
            if index < questions.count - 1 {
                lines.append("")
            }
        }
        return ToolResult(
            text: lines.joined(separator: "\n") + "\n请据此继续推进;除非出现新的关键歧义,不要重复提问。"
        )
    }

    private static func parseQuestions(_ arguments: [String: AnyCodable]) -> [ClarificationQuestion] {
        if let rawQuestions = arguments["questions"]?.value as? [Any] {
            let parsed = rawQuestions.compactMap { raw -> ClarificationQuestion? in
                guard let dict = raw as? [String: Any],
                      let question = (dict["question"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !question.isEmpty
                else { return nil }
                return ClarificationQuestion(
                    question: question,
                    context: (dict["context"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    options: parseOptions(dict["options"]),
                    allowsMultiple: dict["allow_multiple"] as? Bool ?? false,
                    allowsFreeform: dict["allow_freeform"] as? Bool ?? true
                )
            }
            if !parsed.isEmpty { return parsed }
        }
        let question = (arguments["question"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return [] }
        return [
            ClarificationQuestion(
                question: question,
                context: (arguments["context"]?.value as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                options: parseOptions(arguments["options"]?.value),
                allowsMultiple: arguments["allow_multiple"]?.value as? Bool ?? false,
                allowsFreeform: arguments["allow_freeform"]?.value as? Bool ?? true
            ),
        ]
    }

    private static func parseOptions(_ raw: Any?) -> [ClarificationOption] {
        guard let rawOptions = raw as? [Any] else { return [] }
        return rawOptions.compactMap { item in
            guard let dict = item as? [String: Any],
                  let label = (dict["label"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty
            else { return nil }
            return ClarificationOption(
                label: label,
                description: dict["description"] as? String ?? "",
                recommended: dict["recommended"] as? Bool ?? false
            )
        }
    }
}
