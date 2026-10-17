import Foundation

/// 让 Agent 通过自然语言创建声明式插件(只写 SKILL.md/plugin.json)。
public struct CreatePluginTool: Tool {
    public let name = "create_plugin"
    public let spec = ToolSpec(
        name: "create_plugin",
        description: """
        Create a reusable HIVE plugin from the user's description. Use this when the user asks to \
        make a plugin, extension, reusable workflow, or skill pack. The tool writes a plugin project \
        under plugin-studio; it does not execute code. After creation, the user can validate/install it \
        in Plugin Studio.
        """,
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "name": ["type": "string", "description": "插件名称,简短可读"],
                "description": ["type": "string", "description": "插件用途,一句话"],
                "instructions": [
                    "type": "string",
                    "description": "可复用的分步工作流,写给未来的 Agent 看",
                ],
            ]),
            "required": AnyCodable(["name", "description", "instructions"]),
        ]
    )

    private let service: PluginAuthoringService

    public init(service: PluginAuthoringService) {
        self.service = service
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let name = (arguments["name"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (arguments["description"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = arguments["instructions"]?.value as? String ?? ""
        guard !name.isEmpty, !description.isEmpty else {
            throw ToolError.invalidArguments("create_plugin 需要 name 与 description")
        }
        let project = try service.createCustom(
            name: name,
            description: description,
            instructions: instructions
        )
        return ToolResult(
            text: "插件已创建:\(project.manifest.name)(id: \(project.manifest.id))\n路径: \(project.root.path)\n请打开插件工坊校验并安装它。"
        )
    }
}
