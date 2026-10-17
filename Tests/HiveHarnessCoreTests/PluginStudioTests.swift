import Foundation
@testable import HiveHarnessCore
import Testing

private func studioRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hive-plugin-studio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("插件工坊")
struct PluginStudioTests {
    @Test("创建技能包、校验并安装")
    func createValidateInstall() throws {
        let root = try studioRoot()
        let service = PluginAuthoringService(root: root)
        let project = try service.create(name: "我的技能包", template: .skillPack)

        #expect(project.manifest.skills.count == 1)
        #expect(project.files.contains("plugin.json"))
        let report = service.validate(project: project)
        #expect(report.canInstall)
        #expect(report.errors.isEmpty)

        let skillDir = try studioRoot()
        let store = SkillStore(userDirectory: skillDir)
        let installed = try service.install(
            project: project,
            skillStore: store,
            mcpDirectory: try studioRoot()
        )
        #expect(installed.count == 1)
        #expect(store.load(id: installed[0].id) != nil)
    }

    @Test("导出再导入,保留技能并生成新 id")
    func exportImport() throws {
        let root = try studioRoot()
        let service = PluginAuthoringService(root: root)
        let project = try service.create(name: "便携插件", template: .skillPack)
        let data = try service.exportBundle(project: project)

        let otherRoot = try studioRoot()
        let other = PluginAuthoringService(root: otherRoot)
        let imported = try other.importBundle(data: data)
        #expect(imported.manifest.name == "便携插件")
        #expect(imported.files.contains("plugin.json"))
        #expect(imported.files.contains { $0.hasSuffix("SKILL.md") })
        #expect(other.validate(project: imported).canInstall)
    }

    @Test("兼容 skills 目录声明")
    func skillsDirectory() throws {
        let root = try studioRoot()
        let service = PluginAuthoringService(root: root)
        let project = try service.create(name: "目录技能", template: .skillPack)
        let manifestURL = project.root.appendingPathComponent("plugin.json")
        try """
        {"schema":"hive.plugin/v1","id":"dir-skill","name":"目录技能","skills":["skills"]}
        """.write(to: manifestURL, atomically: true, encoding: .utf8)
        let refreshed = try #require(service.listProjects().first)
        let report = service.validate(project: refreshed)
        #expect(report.canInstall)
        let store = SkillStore(userDirectory: try studioRoot())
        let installed = try service.install(
            project: refreshed,
            skillStore: store,
            mcpDirectory: try studioRoot()
        )
        #expect(installed.count == 1)
    }

    @Test("create_plugin:自然语言生成可校验插件")
    func naturalLanguageCreation() async throws {
        let root = try studioRoot()
        let service = PluginAuthoringService(root: root)
        let project = try service.createCustom(
            name: "周报整理",
            description: "把本周工作整理成周报",
            instructions: "1. 收集本周完成项。\n2. 按项目分组。\n3. 输出风险与下周计划。"
        )
        #expect(project.manifest.name == "周报整理")
        #expect(project.manifest.description == "把本周工作整理成周报")
        let report = service.validate(project: project)
        #expect(report.canInstall)
        let skill = try #require(project.files.first { $0.hasSuffix("SKILL.md") })
        let text = try service.readFile(project: project, path: skill)
        #expect(text.contains("收集本周完成项"))

        let tool = CreatePluginTool(service: service)
        let result = try await tool.run(arguments: [
            "name": AnyCodable("代码审查助手"),
            "description": AnyCodable("按清单审查改动"),
            "instructions": AnyCodable("1. 读 diff\n2. 找风险\n3. 给修复建议"),
        ])
        #expect(result.text.contains("代码审查助手"))
        #expect(service.listProjects().count == 2)
    }

    @Test("create_plugin 在对话模式不可用,安全模式可用")
    func creationToolVisibility() {
        #expect(WorkMode.sandbox.allows(tool: "create_plugin"))
        #expect(WorkMode.full.allows(tool: "create_plugin"))
        #expect(!WorkMode.chat.allows(tool: "create_plugin"))
    }

    @Test("导出 Claude 兼容市场索引")
    func marketplaceIndex() throws {
        let root = try studioRoot()
        let service = PluginAuthoringService(root: root)
        _ = try service.create(name: "索引一", template: .skillPack)
        _ = try service.create(name: "索引二", template: .mcpBridge)
        let data = try service.exportMarketplaceIndex(projects: service.listProjects())
        let market = try #require(ClaudeMarketplaceParser.parse(data))
        #expect(market.plugins.count == 2)
        #expect(market.plugins.allSatisfy { $0.source == .relative("./\($0.name)") })
    }

    @Test("MCP 模板默认停用并可安装")
    func mcpTemplate() throws {
        let root = try studioRoot()
        let service = PluginAuthoringService(root: root)
        let project = try service.create(name: "MCP 桥", template: .mcpBridge)
        #expect(project.manifest.mcpServers.count == 1)
        #expect(project.manifest.mcpServers[0].enabled == false)
        #expect(service.validate(project: project).canInstall)

        let mcpDir = try studioRoot()
        _ = try service.install(
            project: project,
            skillStore: SkillStore(userDirectory: try studioRoot()),
            mcpDirectory: mcpDir
        )
        let configs = MCPConfigLoader.load(directory: mcpDir)
        #expect(configs.count == 1)
        #expect(configs[0].enabled == false)
    }

    @Test("缺少 SKILL.md 时校验失败")
    func invalidProject() throws {
        let root = try studioRoot()
        let service = PluginAuthoringService(root: root)
        let project = try service.create(name: "坏插件", template: .skillPack)
        let manifest = project.root.appendingPathComponent("plugin.json")
        try """
        {"schema":"hive.plugin/v1","id":"bad","name":"坏插件","skills":["skills/bad/SKILL.md"]}
        """.write(to: manifest, atomically: true, encoding: .utf8)
        let refreshed = try #require(service.loadProject(id: "bad") ?? service.listProjects().first)
        let report = service.validate(project: refreshed)
        #expect(!report.canInstall)
        #expect(report.errors.contains { $0.message.contains("SKILL.md") })
    }

    @Test("兼容 Claude plugin.json:author 对象 / mcpServers 对象")
    func claudeManifest() throws {
        let raw = """
        {
          "name": "claude-demo",
          "version": "1.2.0",
          "description": "demo",
          "author": {"name": "Jane"},
          "skills": ["skills/demo"],
          "mcpServers": {
            "demo": {"command": "npx", "args": ["-y", "demo-mcp"]}
          }
        }
        """
        let manifest = try #require(PluginManifestParser.parse(Data(raw.utf8)))
        #expect(manifest.id == "claude-demo")
        #expect(manifest.author == "Jane")
        #expect(manifest.skills == ["skills/demo"])
        #expect(manifest.mcpServers.count == 1)
        #expect(manifest.mcpServers[0].id == "demo")
    }
}
