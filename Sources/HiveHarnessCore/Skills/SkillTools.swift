import Foundation

/// 技能工具:让模型发现并加载技能指令。
public enum SkillTools {
    public struct ListSkillsTool: Tool {
        public let name = "list_skills"
        public let spec = ToolSpec(
            name: "list_skills",
            description: "List installed agent skills. Skills are reusable task procedures; use run_skill to load one.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([:]),
            ]
        )
        private let store: SkillStore

        public init(store: SkillStore) {
            self.store = store
        }

        public func run(arguments: [String: AnyCodable]) throws -> ToolResult {
            let skills = store.list()
            guard !skills.isEmpty else {
                return ToolResult(text: "暂无可用技能。")
            }
            return ToolResult(
                text: "可用技能:\n" + skills.map(\.catalogLine).joined(separator: "\n")
            )
        }
    }

    public struct RunSkillTool: Tool {
        public let name = "run_skill"
        public let spec = ToolSpec(
            name: "run_skill",
            description: "Load a skill's full instructions by id, then follow that procedure to complete the task.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "skill_id": ["type": "string", "description": "Skill id from list_skills"]
                ]),
                "required": AnyCodable(["skill_id"]),
            ]
        )
        private let store: SkillStore

        public init(store: SkillStore) {
            self.store = store
        }

        public func run(arguments: [String: AnyCodable]) throws -> ToolResult {
            guard let id = arguments["skill_id"]?.value as? String else {
                throw ToolError.invalidArguments("缺少 skill_id 参数")
            }
            guard let skill = store.load(id: id) else {
                throw ToolError.execution("技能不存在或已停用: \(id)")
            }
            var text = skill.instructions
            if skill.hasHandler {
                text += "\n\n(该技能包含本地 handler;当前版本只注入指令,不会自动执行脚本。)"
            }
            store.recordUse(id: skill.id)
            return ToolResult(text: text)
        }
    }
}
