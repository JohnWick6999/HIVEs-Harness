import CryptoKit
import Foundation
@testable import HiveHarnessCore
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

final class MutableMarketplaceContent: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(_ value: String) { storage = value }

    var value: String {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
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
        .appendingPathComponent("hiveharness-market-skills-\(UUID().uuidString)")
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

    @Test("安装后的 SKILL.md 可被 Agent 技能工具发现并调用")
    func installedSkillIsCallable() throws {
        let store = try marketplaceSkillStore()
        let installer = MarketplaceInstaller(skillStore: store)
        let item = MarketplaceItem(
            id: "github:acme/demo",
            name: "demo",
            summary: "演示插件",
            author: "acme",
            source: .github,
            kind: .plugin,
            installURL: "https://github.com/acme/demo"
        )
        let content = """
        ---
        id: demo-skill
        name: 演示技能
        description: 安装后应能被 Agent 发现
        version: 1.0.0
        enabled: true
        ---

        # 执行步骤
        1. 读取输入
        2. 输出结果
        """
        let plan = MarketplaceInstallPlan(
            item: item,
            files: [
                MarketplaceInstallFile(
                    skillID: "demo-skill",
                    path: "demo-skill/SKILL.md",
                    content: content
                ),
            ],
            ref: "main"
        )
        let installed = try installer.install(plan)
        #expect(installed.count == 1)
        #expect(store.load(id: "demo-skill") != nil)

        let list = try SkillTools.ListSkillsTool(store: store).run(arguments: [:])
        #expect(list.text.contains("demo-skill"))

        let run = try SkillTools.RunSkillTool(store: store).run(arguments: [
            "skill_id": AnyCodable("demo-skill"),
        ])
        #expect(run.text.contains("读取输入"))
    }

    @Test("链接解析:tree / blob / raw 子路径")
    func linkSubpathParsing() {
        #expect(
            MarketplaceLinkParser.parse("https://github.com/acme/tools/tree/dev/skills/foo")
                == .github(owner: "acme", repo: "tools", ref: "dev")
        )
        #expect(
            MarketplaceLinkParser.installPath("https://github.com/acme/tools/tree/dev/skills/foo")
                == "skills/foo"
        )
        #expect(
            MarketplaceLinkParser.installPath("https://github.com/acme/tools/blob/dev/skills/foo/SKILL.md")
                == "skills/foo"
        )
        #expect(
            MarketplaceLinkParser.installPath("https://raw.githubusercontent.com/acme/tools/dev/skills/foo/SKILL.md")
                == "skills/foo"
        )
        #expect(
            MarketplaceLinkParser.installPath("https://raw.githubusercontent.com/acme/tools/dev/plugin.json")
                == nil
        )
        #expect(
            MarketplaceLinkParser.installPath("https://github.com/acme/tools/blob/dev/.claude-plugin/plugin.json")
                == nil
        )
        #expect(
            MarketplaceLinkParser.parse("https://raw.githubusercontent.com/acme/tools/dev/skills/foo/SKILL.md")
                == .github(owner: "acme", repo: "tools", ref: "dev")
        )
    }

    @Test("GitLab / Gitee 链接解析")
    func otherGitLinkParsing() {
        #expect(
            MarketplaceLinkParser.parse("https://gitlab.com/acme/tools")
                == .gitLab(owner: "acme", repo: "tools", ref: nil)
        )
        #expect(
            MarketplaceLinkParser.parse("https://gitlab.com/acme/tools/-/tree/dev")
                == .gitLab(owner: "acme", repo: "tools", ref: "dev")
        )
        #expect(
            MarketplaceLinkParser.parse("https://gitee.com/acme/tools")
                == .gitee(owner: "acme", repo: "tools", ref: nil)
        )
    }

    @Test("GitLab 导入与安装预检")
    func gitLabPlan() async throws {
        let skill = """
        ---
        id: gl-skill
        name: GitLab 技能
        description: 来自 GitLab
        ---

        1. 读取
        2. 输出
        """
        MarketplaceMockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/repository/tree") {
                return httpJSON(request, [
                    ["path": "SKILL.md", "type": "blob"],
                ])
            }
            if url.contains("/repository/files/") && url.contains("/raw") {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!
                return (response, Data(skill.utf8))
            }
            if url.contains("/api/v4/projects/") {
                return httpJSON(request, [
                    "name": "tools",
                    "description": "gitlab tools",
                    "default_branch": "main",
                    "star_count": 3,
                    "web_url": "https://gitlab.com/acme/tools",
                ])
            }
            return httpJSON(request, [:])
        }

        let store = try marketplaceSkillStore()
        let installer = MarketplaceInstaller(session: marketplaceSession(), skillStore: store)
        let item = MarketplaceItem(
            id: "gitlab:acme/tools",
            name: "tools",
            summary: "",
            source: .gitLab,
            kind: .plugin,
            installURL: "https://gitlab.com/acme/tools"
        )
        let plan = try await installer.plan(for: item)
        #expect(plan.files.count == 1)
        #expect(plan.files[0].skillID == "gl-skill")
    }

    @Test("npm 链接解析与声明式安装")
    func npmPlan() async throws {
        #expect(MarketplaceLinkParser.parse("npm:my-skill") == .npm(package: "my-skill"))
        #expect(
            MarketplaceLinkParser.parse("https://www.npmjs.com/package/my-skill")
                == .npm(package: "my-skill")
        )

        let skill = """
        ---
        id: npm-skill
        name: npm 技能
        description: 来自 npm
        ---

        1. 执行
        """
        MarketplaceMockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("?meta") {
                return httpJSON(request, [
                    "files": [["path": "SKILL.md", "type": "file", "size": skill.utf8.count]],
                ])
            }
            if url.contains("/SKILL.md") {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!
                return (response, Data(skill.utf8))
            }
            return httpJSON(request, [
                "name": "my-skill",
                "version": "1.0.0",
                "description": "npm skill",
                "license": "MIT",
            ])
        }

        let store = try marketplaceSkillStore()
        let installer = MarketplaceInstaller(session: marketplaceSession(), skillStore: store)
        let item = MarketplaceItem(
            id: "npm:my-skill",
            name: "my-skill",
            summary: "",
            source: .npm,
            kind: .plugin,
            installURL: "https://www.npmjs.com/package/my-skill"
        )
        let plan = try await installer.plan(for: item)
        #expect(plan.files.count == 1)
        #expect(plan.files[0].skillID == "npm-skill")
        #expect(plan.ref == "latest")
    }

    @Test("直链 .hiveplugin 解析、导入与安装")
    func hivePluginBundle() async throws {
        #expect(
            MarketplaceLinkParser.parse("https://example.com/demo.hiveplugin.json")
                == .hivePlugin(url: "https://example.com/demo.hiveplugin.json")
        )

        let manifest = PluginManifest(
            id: "bundle-demo",
            name: "直链插件",
            skills: ["skills/demo/SKILL.md"]
        )
        let content = """
        ---
        id: bundle-demo-skill
        name: 直链技能
        description: 从插件包安装
        ---

        1. 读取输入
        2. 输出结果
        """
        let bundle = PluginBundle(
            manifest: manifest,
            files: ["skills/demo/SKILL.md": content, "plugin.json": "{}"]
        )
        let data = try JSONEncoder().encode(bundle)
        MarketplaceMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let service = MarketplaceService(session: marketplaceSession())
        let item = try await service.importLink("https://example.com/demo.hiveplugin.json")
        #expect(item.source == .web)
        #expect(item.pluginBundle != nil)

        let store = try marketplaceSkillStore()
        let installer = MarketplaceInstaller(session: marketplaceSession(), skillStore: store)
        let plan = try await installer.plan(for: item)
        #expect(plan.files.count == 1)
        let installed = try installer.install(plan)
        #expect(installed.first?.id == "bundle-demo-skill")
        #expect(store.load(id: "bundle-demo-skill") != nil)
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

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("更新状态可判断是否可更新")
    func updateStatusFlag() {
        #expect(MarketplaceUpdateStatus.available(current: "a", latest: "b").isUpdateAvailable)
        #expect(!MarketplaceUpdateStatus.upToDate.isUpdateAvailable)
        #expect(!MarketplaceUpdateStatus.unknown.isUpdateAvailable)
    }

    @Test("GitHub blob SHA-1 校验算法")
    func gitBlobHash() {
        #expect(
            MarketplaceInstaller.gitBlobSHA1("hello\n")
                == "ce013625030ba8dba906f756967f9e9ca394464a"
        )
    }

    @Test("ModelScope Sha256 校验 + 安装来源清单")
    func integrityProvenance() async throws {
        let content = """
        ---
        name: verified-skill
        description: 已校验技能
        ---

        1. 读取输入
        2. 输出结果
        """
        let hash = digest(content)
        MarketplaceMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/repo/files") {
                return httpJSON(request, [
                    "Code": 200,
                    "Data": ["Files": [
                        ["Path": "SKILL.md", "Type": "blob", "Size": content.utf8.count, "Sha256": hash],
                    ]],
                ])
            }
            if path.hasSuffix("/resolve/master/SKILL.md") {
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
            id: "modelscope:@acme/verified",
            name: "verified",
            summary: "",
            source: .modelScope,
            installURL: "https://modelscope.cn/skills/@acme/verified"
        )
        let plan = try await installer.plan(for: item)
        #expect(plan.files.count == 1)
        #expect(plan.files[0].sha256 == hash)
        #expect(plan.files[0].remoteHash == hash)
        _ = try installer.install(plan)

        let skill = try #require(store.load(id: "verified"))
        #expect(skill.marketplace?.itemID == item.id)
        #expect(skill.marketplace?.sha256 == hash)
        #expect(skill.marketplace?.remoteHash == hash)
    }

    @Test("检查更新并一键更新,更新前自动备份")
    func updateFlow() async throws {
        let contentA = """
        ---
        name: updatable
        description: v1
        ---

        1. 版本一
        """
        let contentB = """
        ---
        name: updatable
        description: v2
        ---

        1. 版本二
        2. 新增步骤
        """
        let box = MutableMarketplaceContent(contentA)

        MarketplaceMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/repo/files") {
                return httpJSON(request, [
                    "Code": 200,
                    "Data": ["Files": [
                        ["Path": "SKILL.md", "Type": "blob", "Size": box.value.utf8.count, "Sha256": SHA256.hash(data: Data(box.value.utf8)).map { String(format: "%02x", $0) }.joined()],
                    ]],
                ])
            }
            if path.hasSuffix("/resolve/master/SKILL.md") {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )!
                return (response, Data(box.value.utf8))
            }
            return httpJSON(request, [:])
        }

        let store = try marketplaceSkillStore()
        let installer = MarketplaceInstaller(session: marketplaceSession(), skillStore: store)
        let item = MarketplaceItem(
            id: "modelscope:@acme/updatable",
            name: "updatable",
            summary: "",
            source: .modelScope,
            installURL: "https://modelscope.cn/skills/@acme/updatable"
        )
        _ = try installer.install(try await installer.plan(for: item))
        let installed = try #require(store.load(id: "updatable"))
        #expect(installed.body.contains("版本一"))

        box.value = contentB
        let status = try await installer.checkUpdate(for: installed)
        guard case .available = status else {
            Issue.record("expected update available")
            return
        }

        let updated = try await installer.update(installed)
        #expect(updated.first?.body.contains("版本二") == true)
        #expect(store.load(id: "updatable")?.body.contains("版本二") == true)
        #expect(!store.versions(id: "updatable").isEmpty)
    }

    @Test("Claude marketplace.json 解析与展开")
    func expandClaudeMarketplace() async throws {
        MarketplaceMockURLProtocol.handler = { request in
            guard request.url?.host == "raw.githubusercontent.com" else {
                return httpJSON(request, [:])
            }
            let content = """
            {"name":"acme-market","owner":{"name":"Acme"},"plugins":[
              {"name":"pdf-tools","description":"PDF 工具","version":"1.0.0","category":"docs","tags":["pdf"],"source":"./plugins/pdf"},
              {"name":"remote-tools","description":"远程插件","source":{"source":"github","repo":"acme/remote","sha":"abc"}}
            ]}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(content.utf8))
        }

        let service = MarketplaceService(session: marketplaceSession())
        let item = MarketplaceItem(
            id: "github:acme/market",
            name: "market",
            summary: "",
            source: .github,
            kind: .plugin,
            installURL: "https://github.com/acme/market"
        )
        let children = try await service.expand(item: item)
        #expect(children.count == 2)
        #expect(children[0].name == "pdf-tools")
        #expect(children[0].installPath == "plugins/pdf")
        #expect(children[1].name == "remote-tools")
        #expect(children[1].installURL == "https://github.com/acme/remote")
    }

    @Test("安装子目录插件时只读取该目录")
    func installSubdirectory() async throws {
        MarketplaceMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/repos/acme/multi" {
                return httpJSON(request, [
                    "name": "multi",
                    "full_name": "acme/multi",
                    "description": "multi",
                    "default_branch": "main",
                    "html_url": "https://github.com/acme/multi",
                    "owner": ["login": "acme"],
                ])
            }
            if path == "/repos/acme/multi/git/trees/main" {
                return httpJSON(request, [
                    "tree": [
                        ["path": "plugins/pdf/SKILL.md", "type": "blob", "size": 100],
                        ["path": "other/SKILL.md", "type": "blob", "size": 100],
                    ]
                ])
            }
            if request.url?.host == "raw.githubusercontent.com" {
                let content = """
                ---
                id: pdf-skill
                name: PDF 工具
                description: 处理 PDF
                ---

                1. 读取 PDF
                2. 提取文本
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
            id: "github:acme/multi/pdf",
            name: "pdf",
            summary: "",
            source: .github,
            installURL: "https://github.com/acme/multi",
            installPath: "plugins/pdf"
        )
        let plan = try await installer.plan(for: item)
        #expect(plan.files.count == 1)
        #expect(plan.files[0].skillID == "pdf-skill")
    }

    @Test("插件包一次安装多个技能")
    func multiSkillBundle() async throws {
        MarketplaceMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/repos/acme/bundle" {
                return httpJSON(request, [
                    "name": "bundle",
                    "full_name": "acme/bundle",
                    "description": "multi skill bundle",
                    "default_branch": "main",
                    "html_url": "https://github.com/acme/bundle",
                    "owner": ["login": "acme"],
                ])
            }
            if path == "/repos/acme/bundle/git/trees/main" {
                return httpJSON(request, [
                    "tree": [
                        ["path": "skills/one/SKILL.md", "type": "blob", "size": 120],
                        ["path": "skills/two/SKILL.md", "type": "blob", "size": 120],
                    ]
                ])
            }
            if request.url?.host == "raw.githubusercontent.com" {
                let isOne = path.contains("/skills/one/")
                let content = """
                ---
                id: \(isOne ? "bundle-one" : "bundle-two")
                name: \(isOne ? "技能一" : "技能二")
                description: 子技能
                ---

                1. 执行步骤
                2. 输出结果
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
            id: "github:acme/bundle",
            name: "bundle",
            summary: "",
            source: .github,
            kind: .plugin,
            installURL: "https://github.com/acme/bundle"
        )
        let plan = try await installer.plan(for: item)
        #expect(plan.files.count == 2)
        #expect(Set(plan.files.map(\.skillID)) == ["bundle-one", "bundle-two"])

        let installed = try installer.install(plan)
        #expect(installed.count == 2)
        #expect(store.load(id: "bundle-one") != nil)
        #expect(store.load(id: "bundle-two") != nil)
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
            .appendingPathComponent("hiveharness-market-mcp-\(UUID().uuidString)")
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

    @Test("导入 GitHub 子目录链接时限定安装路径")
    func importSubpath() async throws {
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
        let item = try await service.importLink("https://github.com/acme/skills/tree/main/skills/foo")
        #expect(item.installPath == "skills/foo")
        #expect(item.name == "foo")
    }
}
