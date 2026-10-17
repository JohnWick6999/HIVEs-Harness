import Foundation
@testable import ShizukuCore
import Testing

final class MarketplaceMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func marketplaceSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MarketplaceMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func httpJSON(_ request: URLRequest, _ object: Any) -> (HTTPURLResponse, Data) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, data)
}

private func marketplaceSkillStore() throws -> SkillStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("shizuku-market-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return SkillStore(userDirectory: dir)
}

@Suite("插件市场", .serialized)
struct MarketplaceTests {
    @Test("链接解析:GitHub / ModelScope")
    func linkParsing() {
        #expect(
            MarketplaceLinkParser.parse("https://github.com/anthropics/claude-plugins-official")
                == .github(owner: "anthropics", repo: "claude-plugins-official", ref: nil)
        )
        #expect(
            MarketplaceLinkParser.parse("github.com/acme/tools.git")
                == .github(owner: "acme", repo: "tools", ref: nil)
        )
        #expect(
            MarketplaceLinkParser.parse("https://github.com/acme/tools/tree/dev")
                == .github(owner: "acme", repo: "tools", ref: "dev")
        )
        #expect(
            MarketplaceLinkParser.parse("https://modelscope.cn/skills/@anthropics/skill-creator")
                == .modelScopeSkill(owner: "@anthropics", name: "skill-creator")
        )
        #expect(
            MarketplaceLinkParser.parse("https://modelscope.cn/models/acme/model")
                == .modelScopeModel(owner: "acme", name: "model")
        )
        #expect(MarketplaceLinkParser.parse("https://example.com/x") == nil)
    }

    @Test("ModelScope JSON 多外壳解析")
    func modelScopeParsing() {
        let data = Data(
            """
            {"data":{"skills":[
              {"id":"skill-creator","name":"Skill Creator","description":"创建技能",
               "owner":{"name":"anthropics"},"downloads":321,"tags":["agent","skills"],
               "license":"MIT","source_url":"https://github.com/anthropics/skills",
               "install_command":"npx skills add ..."}
            ]}}
            """.utf8
        )
        let items = ModelScopeMarketplaceClient.parseItems(data)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.id == "modelscope:skill-creator")
        #expect(item.name == "Skill Creator")
        #expect(item.author == "anthropics")
        #expect(item.downloads == 321)
        #expect(item.tags == ["agent", "skills"])
        #expect(item.installCommand == "npx skills add ...")
    }

    @Test("GitHub 搜索与仓库解析")
    func githubParsing() async throws {
        MarketplaceMockURLProtocol.handler = { request in
            if request.url?.path == "/search/repositories" {
                return httpJSON(request, [
                    "items": [[
                        "name": "tools",
                        "full_name": "acme/tools",
                        "description": "Agent tools",
                        "stargazers_count": 42,
                        "default_branch": "main",
                        "html_url": "https://github.com/acme/tools",
                        "license": ["spdx_id": "MIT"],
                        "topics": ["agent", "skills"],
                        "owner": ["login": "acme", "avatar_url": "https://x/a.png"],
                    ]]
                ])
            }
            return httpJSON(request, [:])
        }

        let client = GitHubMarketplaceClient(session: marketplaceSession())
        let items = try await client.searchRepositories(query: "")
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.id == "github:acme/tools")
        #expect(item.stars == 42)
        #expect(item.license == "MIT")
    }

    @Test("内置目录可解码")
    func builtinDecode() throws {
        let url = try #require(Bundle.module.url(forResource: "MarketplaceCatalog", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let items = try JSONDecoder().decode([MarketplaceItem].self, from: data)
        #expect(items.count >= 7)
    }

    @Test("内置目录无需网络")
    func builtinCatalog() async {
        let service = MarketplaceService(session: marketplaceSession())
        let builtin = await service.builtinItems()
        #expect(builtin.count >= 7)
        #expect(builtin.contains { $0.id == "builtin:code-review" })

        let result = await service.feed(query: "review", source: .builtin)
        #expect(result.items.contains { $0.id == "builtin:code-review" })
        #expect(result.errors.isEmpty)
    }

    @Test("安装计划与安装:只写 SKILL.md")
    func installFromGitHub() async throws {
        MarketplaceMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/repos/acme/skills":
                return httpJSON(request, [
                    "name": "skills",
                    "full_name": "acme/skills",
                    "description": "acme skills",
                    "stargazers_count": 10,
                    "default_branch": "main",
                    "html_url": "https://github.com/acme/skills",
                    "owner": ["login": "acme", "avatar_url": "https://x/a.png"],
                ])
            case "/repos/acme/skills/git/trees/main":
                return httpJSON(request, [
                    "tree": [
                        ["path": "skills/review/SKILL.md", "type": "blob", "size": 120],
                        ["path": "skills/review/handler.sh", "type": "blob", "size": 20],
                    ]
                ])
            default:
                if request.url?.host == "raw.githubusercontent.com" {
                    let content = """
                    ---
                    id: review-skill
                    name: Review Skill
                    description: review code
                    ---

                    1. 读取文件
                    2. 输出问题
                    """
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/plain"]
                    )!
                    return (response, Data(content.utf8))
                }
                return httpJSON(request, [:])
            }
        }

        let store = try marketplaceSkillStore()
        let installer = MarketplaceInstaller(session: marketplaceSession(), skillStore: store)
        let item = MarketplaceItem(
            id: "github:acme/skills",
            name: "skills",
            summary: "acme skills",
            author: "acme",
            source: .github,
            installURL: "https://github.com/acme/skills"
        )

        let plan = try await installer.plan(for: item)
        #expect(plan.files.count == 1)
        #expect(plan.files[0].skillID == "review-skill")
        #expect(plan.warnings.contains { $0.contains("handler") })

        let installed = try installer.install(plan)
        #expect(installed.count == 1)
        #expect(installed[0].id == "review-skill")
        #expect(store.load(id: "review-skill") != nil)
        #expect(store.load(id: "review-skill")?.body.contains("输出问题") == true)
    }

    @Test("ModelScope 安装:repo/files + resolve 原始 SKILL.md")
    func installFromModelScope() async throws {
        MarketplaceMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/repo/files") {
                return httpJSON(request, [
                    "Code": 200,
                    "Data": ["Files": [
                        ["Path": "SKILL.md", "Type": "blob", "Size": 120],
                        ["Path": "scripts/run.sh", "Type": "blob", "Size": 20],
                    ]],
                ])
            }
            if path.hasSuffix("/resolve/master/SKILL.md") {
                let content = """
                ---
                name: skill-creator
                description: 创建技能
                ---

                # 流程
                1. 明确目标
                2. 生成技能
                """
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!
                return (response, Data(content.utf8))
            }
            return httpJSON(request, [:])
        }

        let store = try marketplaceSkillStore()
        let installer = MarketplaceInstaller(session: marketplaceSession(), skillStore: store)
        let item = MarketplaceItem(
            id: "modelscope:@anthropics/skill-creator",
            name: "skill-creator",
            summary: "创建技能",
            source: .modelScope,
            installURL: "https://modelscope.cn/skills/@anthropics/skill-creator"
        )

        let plan = try await installer.plan(for: item)
        #expect(plan.files.count == 1)
        #expect(plan.files[0].skillID == "skill-creator")
        #expect(plan.warnings.contains { $0.contains("脚本") })

        let installed = try installer.install(plan)
        #expect(installed.count == 1)
        #expect(store.load(id: "skill-creator") != nil)
    }

    @Test("MCP 清单一键安装并默认停用")
    func installMCPFromGitHub() async throws {
        MarketplaceMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/repos/acme/mcp" {
                return httpJSON(request, [
                    "name": "mcp",
                    "full_name": "acme/mcp",
                    "description": "mcp bundle",
                    "default_branch": "main",
                    "html_url": "https://github.com/acme/mcp",
                    "owner": ["login": "acme"],
                ])
            }
            if path == "/repos/acme/mcp/git/trees/main" {
                return httpJSON(request, [
                    "tree": [["path": "mcp.json", "type": "blob", "size": 100]]
                ])
            }
            if request.url?.host == "raw.githubusercontent.com" {
                let content = #"{"mcpServers":{"demo":{"command":"npx","args":["-y","demo-mcp"]}}}"#
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!
                return (response, Data(content.utf8))
            }
            return httpJSON(request, [:])
        }

        let store = try marketplaceSkillStore()
        let mcpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-market-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
        let installer = MarketplaceInstaller(
            session: marketplaceSession(),
            skillStore: store,
            mcpDirectory: mcpDir
        )
        let item = MarketplaceItem(
            id: "github:acme/mcp",
            name: "mcp",
            summary: "mcp bundle",
            source: .github,
            installURL: "https://github.com/acme/mcp"
        )

        let plan = try await installer.plan(for: item)
        #expect(plan.files.isEmpty)
        #expect(plan.mcpServers.count == 1)
        #expect(plan.mcpServers[0].enabled == false)
        #expect(plan.mcpServers[0].type == "stdio")

        _ = try installer.install(plan)
        let configs = MCPConfigLoader.load(directory: mcpDir)
        #expect(configs.count == 1)
        #expect(configs[0].id == "demo")
        #expect(configs[0].command == "npx")
    }

    @Test("没有 SKILL.md 时拒绝安装")
    func noSkillRejected() async throws {
        MarketplaceMockURLProtocol.handler = { request in
            if request.url?.path == "/repos/acme/plugin" {
                return httpJSON(request, [
                    "name": "plugin",
                    "full_name": "acme/plugin",
                    "description": "plugin only",
                    "default_branch": "main",
                    "html_url": "https://github.com/acme/plugin",
                    "owner": ["login": "acme"],
                ])
            }
            return httpJSON(request, [
                "tree": [["path": ".claude-plugin/plugin.json", "type": "blob", "size": 20]]
            ])
        }

        let store = try marketplaceSkillStore()
        let installer = MarketplaceInstaller(session: marketplaceSession(), skillStore: store)
        let item = MarketplaceItem(
            id: "github:acme/plugin",
            name: "plugin",
            summary: "",
            source: .github,
            installURL: "https://github.com/acme/plugin"
        )

        await #expect(throws: MarketplaceError.self) {
            _ = try await installer.plan(for: item)
        }
    }

    @Test("导入 GitHub 链接")
    func importLink() async throws {
        MarketplaceMockURLProtocol.handler = { request in
            httpJSON(request, [
                "name": "skills",
                "full_name": "acme/skills",
                "description": "acme skills",
                "stargazers_count": 7,
                "default_branch": "main",
                "html_url": "https://github.com/acme/skills",
                "owner": ["login": "acme"],
            ])
        }
        let service = MarketplaceService(session: marketplaceSession())
        let item = try await service.importLink("https://github.com/acme/skills")
        #expect(item.id == "github:acme/skills")
        #expect(item.stars == 7)
    }
}
