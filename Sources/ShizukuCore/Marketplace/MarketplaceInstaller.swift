import CryptoKit
import Foundation

public enum MarketplaceUpdateStatus: Sendable, Equatable {
    case upToDate
    case available(current: String, latest: String)
    case unknown
}

public struct MarketplaceInstallFile: Sendable, Equatable {
    public var skillID: String
    public var path: String
    public var content: String
    /// 下载内容 SHA-256(写入来源清单)
    public var sha256: String
    /// 远端声明的校验值(GitHub blob SHA-1 / ModelScope Sha256)
    public var remoteHash: String?

    public init(
        skillID: String,
        path: String,
        content: String,
        sha256: String = "",
        remoteHash: String? = nil
    ) {
        self.skillID = skillID
        self.path = path
        self.content = content
        self.sha256 = sha256
        self.remoteHash = remoteHash
    }
}

/// 安装前预览:文件、风险提示、将被覆盖的技能。
public struct MarketplaceInstallPlan: Sendable, Equatable {
    public var item: MarketplaceItem
    public var files: [MarketplaceInstallFile]
    public var warnings: [String]
    public var overwriting: [String]
    public var ref: String
    public var isBuiltin: Bool
    /// 随包安装的 MCP 服务器(默认停用)
    public var mcpServers: [MCPServerConfig]

    public init(
        item: MarketplaceItem,
        files: [MarketplaceInstallFile] = [],
        warnings: [String] = [],
        overwriting: [String] = [],
        ref: String = "",
        isBuiltin: Bool = false,
        mcpServers: [MCPServerConfig] = []
    ) {
        self.item = item
        self.files = files
        self.warnings = warnings
        self.overwriting = overwriting
        self.ref = ref
        self.isBuiltin = isBuiltin
        self.mcpServers = mcpServers
    }
}

/// 市场安装器:首版只安装 SKILL.md,不执行仓库里的脚本/hook。
public struct MarketplaceInstaller: Sendable {
    private let github: GitHubMarketplaceClient
    private let modelScope: ModelScopeMarketplaceClient
    private let skillStore: SkillStore
    private let mcpDirectory: URL?

    public init(
        githubToken: String? = nil,
        session: URLSession = .shared,
        skillStore: SkillStore,
        mcpDirectory: URL? = nil
    ) {
        self.github = GitHubMarketplaceClient(session: session, token: githubToken)
        self.modelScope = ModelScopeMarketplaceClient(session: session)
        self.skillStore = skillStore
        self.mcpDirectory = mcpDirectory
    }

    public func plan(for item: MarketplaceItem) async throws -> MarketplaceInstallPlan {
        if item.source == .builtin {
            return MarketplaceInstallPlan(
                item: item,
                warnings: ["内置技能已随 App 预装,无需下载。"],
                isBuiltin: true
            )
        }
        if item.kind == .mcp {
            throw MarketplaceError.invalidPackage("MCP 服务器安装将在下一版支持;请先通过设置 → MCP 手动添加。")
        }
        if item.source == .modelScope {
            return try await planModelScope(item)
        }

        guard let target = githubTarget(for: item) else {
            let hint = item.installCommand.map { "该来源提供安装命令: \($0)" } ?? ""
            throw MarketplaceError.unsupportedSource(
                "\(item.source.title) 条目没有可用的 GitHub 源。\(hint)"
            )
        }
        let repository = try await github.repository(owner: target.owner, repo: target.repo)
        let ref = target.ref ?? repository.defaultBranch
        let fullTree = try await github.tree(owner: target.owner, repo: target.repo, ref: ref)
        let prefix = item.installPath?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let tree = prefix.isEmpty
            ? fullTree
            : fullTree.filter { $0.path == prefix || $0.path.hasPrefix(prefix + "/") }
        let mcpServers = try await parseMCPServers(
            tree: tree,
            owner: target.owner,
            repo: target.repo,
            ref: ref
        )

        let candidates = tree.filter { entry in
            guard entry.type == "blob", entry.path.hasSuffix("SKILL.md") else { return false }
            guard !entry.path.contains(".."), !entry.path.hasPrefix("/") else { return false }
            let blocked = ["node_modules/", ".git/", "vendor/", "dist/", "build/"]
            return !blocked.contains { entry.path.hasPrefix($0) }
        }

        guard !candidates.isEmpty else {
            if !mcpServers.isEmpty {
                return MarketplaceInstallPlan(
                    item: item,
                    warnings: ["MCP 服务器会启动外部进程或访问网络,安装后默认停用。"],
                    ref: ref,
                    mcpServers: mcpServers
                )
            }
            let hasPluginManifest = tree.contains {
                $0.path.hasSuffix("plugin.json") || $0.path.hasSuffix("marketplace.json") || $0.path.hasSuffix("server.json")
            }
            if hasPluginManifest {
                throw MarketplaceError.invalidPackage("这是插件/市场目录,未找到可直接安装的 SKILL.md。")
            }
            throw MarketplaceError.noInstallableSkill
        }

        var warnings: [String] = []
        if candidates.count > 12 {
            warnings.append("仓库包含 \(candidates.count) 个技能,首版只安装前 12 个。")
        }
        let risky = tree.contains {
            $0.path.hasSuffix("handler.sh")
                || $0.path.hasSuffix("handler.py")
                || $0.path.contains("hooks/")
                || $0.path.hasPrefix("bin/")
                || $0.path.hasSuffix(".mcp.json")
        }
        if risky {
            warnings.append("仓库包含 handler / hook / bin / MCP 组件;首版只安装 SKILL.md,不会执行脚本。")
        }

        var files: [MarketplaceInstallFile] = []
        var usedIDs = Set<String>()
        for entry in candidates.prefix(12) {
            if let size = entry.size, size > 512_000 {
                warnings.append("跳过过大文件: \(entry.path)")
                continue
            }
            let content = try await github.rawFile(
                owner: target.owner,
                repo: target.repo,
                ref: ref,
                path: entry.path
            )
            guard content.utf8.count <= 512_000 else {
                warnings.append("跳过超大内容: \(entry.path)")
                continue
            }
            if let expected = entry.sha, !expected.isEmpty,
               Self.gitBlobSHA1(content) != expected.lowercased() {
                warnings.append("Git blob 校验失败,已跳过: \(entry.path)")
                continue
            }
            let meta = SkillStore.parseFrontmatter(content).meta
            let declared = (meta["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent().lastPathComponent
            let base = declared.isEmpty
                ? (entry.path == "SKILL.md" ? repository.name : parent)
                : declared
            let id = Self.uniqueID(Self.sanitize(base), used: &usedIDs)
            files.append(
                MarketplaceInstallFile(
                    skillID: id,
                    path: entry.path,
                    content: content,
                    sha256: Self.sha256(content),
                    remoteHash: entry.sha
                )
            )
        }

        guard !files.isEmpty else { throw MarketplaceError.noInstallableSkill }
        let existing = Set(skillStore.all().map(\.id))
        let overwriting = files.map(\.skillID).filter { existing.contains($0) }
        if !mcpServers.isEmpty {
            warnings.append("随包安装 \(mcpServers.count) 个 MCP 服务器(默认停用)。")
        }
        return MarketplaceInstallPlan(
            item: item,
            files: files,
            warnings: warnings,
            overwriting: overwriting,
            ref: ref,
            mcpServers: mcpServers
        )
    }

    /// 执行安装(网络读取已在 plan 阶段完成)。
    @discardableResult
    public func install(_ plan: MarketplaceInstallPlan) throws -> [Skill] {
        if plan.isBuiltin {
            let id = plan.item.id.replacingOccurrences(of: "builtin:", with: "")
            return skillStore.load(id: id).map { [$0] } ?? []
        }
        guard !plan.files.isEmpty || !plan.mcpServers.isEmpty else {
            throw MarketplaceError.noInstallableSkill
        }
        if !plan.mcpServers.isEmpty {
            guard let mcpDirectory else {
                throw MarketplaceError.invalidPackage("未配置 MCP 目录,无法安装服务器")
            }
            var existing = MCPConfigLoader.load(directory: mcpDirectory)
            let existingIDs = Set(existing.map(\.id))
            existing.append(contentsOf: plan.mcpServers.filter { !existingIDs.contains($0.id) })
            try MCPConfigLoader.save(existing, directory: mcpDirectory)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-market-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var installed: [Skill] = []
        for file in plan.files {
            let directory = root.appendingPathComponent(file.skillID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try file.content.write(
                to: directory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            let provenance = MarketplaceProvenance(
                itemID: plan.item.id,
                name: plan.item.name,
                source: plan.item.source.rawValue,
                installURL: plan.item.installURL ?? "",
                ref: plan.ref,
                sha256: file.sha256,
                remoteHash: file.remoteHash,
                installPath: plan.item.installPath
            )
            if let data = try? JSONEncoder().encode(provenance) {
                try? data.write(
                    to: directory.appendingPathComponent(".marketplace.json"),
                    options: .atomic
                )
            }
            installed.append(try skillStore.install(from: directory))
        }
        return installed
    }

    // MARK: - 更新检查

    /// 对比已安装技能与远端最新内容的 sha256。
    public func checkUpdate(for skill: Skill) async throws -> MarketplaceUpdateStatus {
        guard let provenance = skill.marketplace,
              let source = MarketplaceSource(rawValue: provenance.source)
        else { return .unknown }
        let item = MarketplaceItem(
            id: provenance.itemID,
            name: provenance.name,
            summary: "",
            source: source,
            kind: .plugin,
            installURL: provenance.installURL,
            installPath: provenance.installPath
        )
        let plan = try await plan(for: item)
        let match = plan.files.first { $0.skillID == skill.id }
        guard let match else { return .unknown }
        if match.sha256 == provenance.sha256 {
            return .upToDate
        }
        return .available(current: provenance.sha256, latest: match.sha256)
    }

    /// 更新已安装技能(覆盖前由 SkillStore 自动备份)。
    @discardableResult
    public func update(_ skill: Skill) async throws -> [Skill] {
        guard let provenance = skill.marketplace,
              let source = MarketplaceSource(rawValue: provenance.source)
        else { throw MarketplaceError.invalidPackage("该技能没有市场来源") }
        let item = MarketplaceItem(
            id: provenance.itemID,
            name: provenance.name,
            summary: "",
            source: source,
            kind: .plugin,
            installURL: provenance.installURL,
            installPath: provenance.installPath
        )
        let plan = try await plan(for: item)
        return try install(plan)
    }

    // MARK: - ModelScope

    private func planModelScope(_ item: MarketplaceItem) async throws -> MarketplaceInstallPlan {
        let rawID: String
        if item.id.hasPrefix("modelscope:") {
            rawID = String(item.id.dropFirst("modelscope:".count))
        } else if let url = item.installURL,
                  case let .modelScopeSkill(owner, name) = MarketplaceLinkParser.parse(url) {
            rawID = "\(owner)/\(name)"
        } else {
            throw MarketplaceError.invalidPackage("ModelScope 技能 id 缺失")
        }
        guard !rawID.isEmpty else {
            throw MarketplaceError.invalidPackage("ModelScope 技能 id 缺失")
        }

        let files = try await modelScope.files(id: rawID)
        let candidates = files.filter {
            $0.type != "tree"
                && $0.path.hasSuffix("SKILL.md")
                && !$0.path.contains("..")
                && !$0.path.hasPrefix("/")
        }
        guard !candidates.isEmpty else {
            throw MarketplaceError.noInstallableSkill
        }

        var warnings: [String] = []
        if candidates.count > 12 {
            warnings.append("仓库包含 \(candidates.count) 个技能,首版只安装前 12 个。")
        }
        let risky = files.contains {
            $0.path.hasSuffix(".sh")
                || $0.path.hasSuffix(".py")
                || $0.path.contains("scripts/")
                || $0.path.contains("hooks/")
        }
        if risky {
            warnings.append("仓库包含脚本;首版只安装 SKILL.md,不会执行脚本。")
        }

        var installFiles: [MarketplaceInstallFile] = []
        var usedIDs = Set<String>()
        let folderFallback = rawID.split(separator: "/").last.map(String.init) ?? "skill"
        for entry in candidates.prefix(12) {
            if entry.size > 512_000 {
                warnings.append("跳过过大文件: \(entry.path)")
                continue
            }
            let content = try await modelScope.rawFile(id: rawID, path: entry.path)
            guard !content.isEmpty, content.utf8.count <= 512_000 else {
                warnings.append("跳过空或超大内容: \(entry.path)")
                continue
            }
            let digest = Self.sha256(content)
            if !entry.sha256.isEmpty, entry.sha256.lowercased() != digest {
                warnings.append("ModelScope Sha256 校验失败,已跳过: \(entry.path)")
                continue
            }
            let meta = SkillStore.parseFrontmatter(content).meta
            let declared = (meta["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent().lastPathComponent
            let base = declared.isEmpty
                ? (entry.path == "SKILL.md" ? folderFallback : parent)
                : declared
            let id = Self.uniqueID(Self.sanitize(base), used: &usedIDs)
            installFiles.append(
                MarketplaceInstallFile(
                    skillID: id,
                    path: entry.path,
                    content: content,
                    sha256: digest,
                    remoteHash: entry.sha256.isEmpty ? nil : entry.sha256
                )
            )
        }
        guard !installFiles.isEmpty else { throw MarketplaceError.noInstallableSkill }
        let existing = Set(skillStore.all().map(\.id))
        return MarketplaceInstallPlan(
            item: item,
            files: installFiles,
            warnings: warnings,
            overwriting: installFiles.map(\.skillID).filter { existing.contains($0) },
            ref: "master"
        )
    }

    // MARK: - MCP 清单

    private func parseMCPServers(
        tree: [GitHubTreeEntry],
        owner: String,
        repo: String,
        ref: String
    ) async throws -> [MCPServerConfig] {
        let candidates = tree.filter { entry in
            guard entry.type == "blob" else { return false }
            let name = URL(fileURLWithPath: entry.path).lastPathComponent
            return ["mcp.json", ".mcp.json", "server.json"].contains(name)
        }.prefix(4)

        var result: [MCPServerConfig] = []
        var seen = Set<String>()
        for entry in candidates {
            guard let raw = try? await github.rawFile(
                owner: owner,
                repo: repo,
                ref: ref,
                path: entry.path
            ) else { continue }
            for config in Self.parseMCPJSON(raw) where seen.insert(config.id).inserted {
                result.append(config)
            }
        }
        return result
    }

    static func parseMCPJSON(_ raw: String) -> [MCPServerConfig] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        // Claude / VS Code 风格:{"mcpServers": {"name": {...}}}
        if let servers = object["mcpServers"] as? [String: Any] {
            return servers.compactMap { key, value in
                guard let dict = value as? [String: Any] else { return nil }
                let command = dict["command"] as? String ?? ""
                let url = dict["url"] as? String ?? ""
                if command.isEmpty && url.isEmpty { return nil }
                return MCPServerConfig(
                    id: Self.sanitizeMCPID(key),
                    name: key,
                    description: dict["description"] as? String ?? "",
                    type: url.isEmpty ? "stdio" : "http",
                    command: command,
                    args: dict["args"] as? [String] ?? [],
                    url: url,
                    headers: dict["headers"] as? [String: String] ?? [:],
                    enabled: false
                )
            }
        }

        // MCP Registry server.json
        guard let name = object["name"] as? String else { return [] }
        let display = object["description"] as? String ?? name
        let packages = object["packages"] as? [[String: Any]] ?? []
        if let pkg = packages.first(where: { ($0["registryType"] as? String) == "npm" }),
           let identifier = pkg["identifier"] as? String {
            return [
                MCPServerConfig(
                    id: Self.sanitizeMCPID(name),
                    name: display,
                    description: object["description"] as? String ?? "",
                    type: "stdio",
                    command: "npx",
                    args: ["-y", identifier],
                    enabled: false
                )
            ]
        }
        let remotes = object["remotes"] as? [[String: Any]] ?? []
        if let remote = remotes.first, let url = remote["url"] as? String {
            return [
                MCPServerConfig(
                    id: Self.sanitizeMCPID(name),
                    name: display,
                    description: object["description"] as? String ?? "",
                    type: "http",
                    url: url,
                    enabled: false
                )
            ]
        }
        return []
    }

    static func sanitizeMCPID(_ raw: String) -> String {
        var result = ""
        for character in raw.lowercased() {
            if (character.isASCII && character.isLetter)
                || (character.isASCII && character.isNumber)
                || character == "-" || character == "_" || character == "." {
                result.append(character)
            } else {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return result.isEmpty ? "mcp-server" : String(result.prefix(60))
    }

    // MARK: - 辅助

    private func githubTarget(
        for item: MarketplaceItem
    ) -> (owner: String, repo: String, ref: String?)? {
        for raw in [item.installURL, item.homepage].compactMap({ $0 }) {
            if let link = MarketplaceLinkParser.parse(raw),
               case let .github(owner, repo, ref) = link {
                return (owner, repo, ref)
            }
        }
        return nil
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// GitHub tree 里的 blob sha 是 Git blob SHA-1,不是内容 SHA-1。
    static func gitBlobSHA1(_ text: String) -> String {
        let data = Data(text.utf8)
        var payload = Data("blob \(data.count)\u{0}".utf8)
        payload.append(data)
        return Insecure.SHA1.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sanitize(_ raw: String) -> String {
        var result = ""
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
                result.append(character)
            } else {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return result.isEmpty ? "skill" : String(result.prefix(60))
    }

    static func uniqueID(_ base: String, used: inout Set<String>) -> String {
        var candidate = base
        var index = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        used.insert(candidate)
        return candidate
    }
}
