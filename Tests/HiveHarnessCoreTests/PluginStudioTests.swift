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
