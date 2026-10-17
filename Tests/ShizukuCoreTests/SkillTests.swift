import Foundation
@testable import ShizukuCore
import Testing

private func makeSkillDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("shizuku-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeSkill(
    in root: URL,
    folder: String,
    id: String,
    name: String = "自定义技能",
    enabled: Bool = true
) throws -> URL {
    let dir = root.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let text = """
    ---
    id: \(id)
    name: \(name)
    description: 一个测试技能
    version: 1.0.0
    tags: [test, custom]
    enabled: \(enabled)
    ---

    # 流程
    1. 读取输入
    2. 输出结果
    """
    try text.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    return dir
}

@Suite("技能系统")
struct SkillTests {
    @Test("内置技能随 Bundle 加载")
    func builtinSkills() throws {
        let store = SkillStore(userDirectory: try makeSkillDirectory())
        let skills = store.list()
        #expect(skills.count >= 5)
        #expect(skills.contains { $0.id == "code-review" })
        #expect(skills.allSatisfy { $0.isBuiltin })
    }

    @Test("frontmatter 解析:标量、内联列表、布尔值")
    func frontmatterParsing() {
        let text = """
        ---
        id: test-skill
        name: 测试技能
        description: 一段描述
        version: 1.2.3
        tags: [a, b]
        enabled: false
        ---

        # 正文
        步骤一
        """
        let parsed = SkillStore.parseFrontmatter(text)
        #expect(parsed.meta["id"] as? String == "test-skill")
        #expect(parsed.meta["version"] as? String == "1.2.3")
        #expect(parsed.meta["tags"] as? [String] == ["a", "b"])
        #expect(parsed.meta["enabled"] as? Bool == false)
        #expect(parsed.body.contains("# 正文"))
        #expect(parsed.body.contains("步骤一"))
    }

    @Test("用户技能覆盖内置,停用状态持久化")
    func userSkillAndDisable() throws {
        let dir = try makeSkillDirectory()
        _ = try writeSkill(in: dir, folder: "custom", id: "custom-skill")

        let store = SkillStore(userDirectory: dir)
        #expect(store.list().contains { $0.id == "custom-skill" })
        #expect(store.load(id: "custom-skill") != nil)

        store.setEnabled(false, id: "custom-skill")
        #expect(store.load(id: "custom-skill") == nil)
        #expect(store.all().contains { $0.id == "custom-skill" && !$0.enabled })

        // 新实例应读到同一个停用状态
        let reloaded = SkillStore(userDirectory: dir)
        #expect(reloaded.load(id: "custom-skill") == nil)
    }

    @Test("安装与删除用户技能")
    func installAndRemove() throws {
        let userDir = try makeSkillDirectory()
        let sourceRoot = try makeSkillDirectory()
        let source = try writeSkill(in: sourceRoot, folder: "pkg", id: "installed-skill")

        let store = SkillStore(userDirectory: userDir)
        let installed = try store.install(from: source)
        #expect(installed.id == "installed-skill")
        #expect(store.load(id: "installed-skill") != nil)

        try store.remove(id: "installed-skill")
        #expect(store.load(id: "installed-skill") == nil)
    }

    @Test("list_skills / run_skill 工具")
    func skillTools() throws {
        let dir = try makeSkillDirectory()
        _ = try writeSkill(in: dir, folder: "custom", id: "custom-skill")
        let store = SkillStore(userDirectory: dir)

        let listResult = try SkillTools.ListSkillsTool(store: store)
            .run(arguments: [:])
        #expect(listResult.text.contains("code-review"))
        #expect(listResult.text.contains("custom-skill"))

        let runResult = try SkillTools.RunSkillTool(store: store)
            .run(arguments: ["skill_id": AnyCodable("code-review")])
        #expect(runResult.text.contains("代码审查"))
        #expect(runResult.text.contains("严重级别"))

        store.setEnabled(false, id: "custom-skill")
        #expect(throws: ToolError.self) {
            try SkillTools.RunSkillTool(store: store)
                .run(arguments: ["skill_id": AnyCodable("custom-skill")])
        }
    }

    @Test("run_skill 记录使用次数并持久化")
    func skillUsage() throws {
        let dir = try makeSkillDirectory()
        _ = try writeSkill(in: dir, folder: "custom", id: "custom-skill")
        let store = SkillStore(userDirectory: dir)
        _ = try SkillTools.RunSkillTool(store: store)
            .run(arguments: ["skill_id": AnyCodable("custom-skill")])
        #expect(store.load(id: "custom-skill")?.useCount == 1)

        let reloaded = SkillStore(userDirectory: dir)
        #expect(reloaded.load(id: "custom-skill")?.useCount == 1)
    }

    @Test("归档 30 天未用技能到 _archive")
    func archiveStale() throws {
        let dir = try makeSkillDirectory()
        _ = try writeSkill(in: dir, folder: "old", id: "old-skill")
        let oldTime = Date().addingTimeInterval(-31 * 24 * 60 * 60).timeIntervalSinceReferenceDate
        let usage = "{\"old-skill\":{\"count\":1,\"lastUsed\":\(oldTime)}}"
        try usage.write(
            to: dir.appendingPathComponent(".usage.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = SkillStore(userDirectory: dir)
        #expect(store.load(id: "old-skill") != nil)
        #expect(store.archiveStale(days: 30) == ["old-skill"])
        #expect(store.load(id: "old-skill") == nil)

        let archivedURL = dir.appendingPathComponent("_archive/old-skill/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: archivedURL.path))

        let reloaded = SkillStore(userDirectory: dir)
        #expect(reloaded.load(id: "old-skill") == nil)
    }

    @Test("技能工具在只读模式下可用")
    func workModeAllowsSkills() {
        #expect(WorkMode.chat.allows(tool: "list_skills"))
        #expect(WorkMode.chat.allows(tool: "run_skill"))
        #expect(WorkMode.sandbox.allows(tool: "run_skill"))
    }
}
