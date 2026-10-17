import Foundation

public struct MarketplaceInstallFile: Sendable, Equatable {
    public var skillID: String
    public var path: String
    public var content: String

    public init(skillID: String, path: String, content: String) {
        self.skillID = skillID
        self.path = path
        self.content = content
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

    public init(
        item: MarketplaceItem,
        files: [MarketplaceInstallFile] = [],
        warnings: [String] = [],
        overwriting: [String] = [],
        ref: String = "",
        isBuiltin: Bool = false
    ) {
        self.item = item
        self.files = files
        self.warnings = warnings
        self.overwriting = overwriting
        self.ref = ref
        self.isBuiltin = isBuiltin
    }
}

/// 市场安装器:首版只安装 SKILL.md,不执行仓库里的脚本/hook。
public struct MarketplaceInstaller: Sendable {
    private let github: GitHubMarketplaceClient
    private let skillStore: SkillStore

    public init(
        githubToken: String? = nil,
        session: URLSession = .shared,
        skillStore: SkillStore
    ) {
        self.github = GitHubMarketplaceClient(session: session, token: githubToken)
        self.skillStore = skillStore
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

        guard let target = githubTarget(for: item) else {
            let hint = item.installCommand.map { "该来源提供安装命令: \($0)" } ?? ""
            throw MarketplaceError.unsupportedSource(
                "\(item.source.title) 条目没有可用的 GitHub 源。\(hint)"
            )
        }
        let repository = try await github.repository(owner: target.owner, repo: target.repo)
        let ref = target.ref ?? repository.defaultBranch
        let tree = try await github.tree(owner: target.owner, repo: target.repo, ref: ref)

        let candidates = tree.filter { entry in
            guard entry.type == "blob", entry.path.hasSuffix("SKILL.md") else { return false }
            guard !entry.path.contains(".."), !entry.path.hasPrefix("/") else { return false }
            let blocked = ["node_modules/", ".git/", "vendor/", "dist/", "build/"]
            return !blocked.contains { entry.path.hasPrefix($0) }
        }

        guard !candidates.isEmpty else {
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
            let meta = SkillStore.parseFrontmatter(content).meta
            let declared = (meta["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent().lastPathComponent
            let base = declared.isEmpty
                ? (entry.path == "SKILL.md" ? repository.name : parent)
                : declared
            let id = Self.uniqueID(Self.sanitize(base), used: &usedIDs)
            files.append(
                MarketplaceInstallFile(skillID: id, path: entry.path, content: content)
            )
        }

        guard !files.isEmpty else { throw MarketplaceError.noInstallableSkill }
        let existing = Set(skillStore.all().map(\.id))
        let overwriting = files.map(\.skillID).filter { existing.contains($0) }
        return MarketplaceInstallPlan(
            item: item,
            files: files,
            warnings: warnings,
            overwriting: overwriting,
            ref: ref
        )
    }

    /// 执行安装(网络读取已在 plan 阶段完成)。
    @discardableResult
    public func install(_ plan: MarketplaceInstallPlan) throws -> [Skill] {
        if plan.isBuiltin {
            let id = plan.item.id.replacingOccurrences(of: "builtin:", with: "")
            return skillStore.load(id: id).map { [$0] } ?? []
        }
        guard !plan.files.isEmpty else {
            throw MarketplaceError.noInstallableSkill
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
            installed.append(try skillStore.install(from: directory))
        }
        return installed
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
