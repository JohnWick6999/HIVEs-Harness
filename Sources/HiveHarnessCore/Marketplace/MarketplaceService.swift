import Foundation

/// 市场聚合服务:内置目录 + GitHub + ModelScope,统一去重排序并短时缓存。
public actor MarketplaceService {
    private let github: GitHubMarketplaceClient
    private let gitlab: GitLabMarketplaceClient
    private let gitee: GiteeMarketplaceClient
    private let npm: NpmMarketplaceClient
    private let modelScope: ModelScopeMarketplaceClient
    private let session: URLSession
    private let builtin: [MarketplaceItem]
    private var cache: [String: (date: Date, result: MarketplaceResult)] = [:]
    private var expansions: [String: [MarketplaceItem]] = [:]

    public init(githubToken: String? = nil, session: URLSession = .shared) {
        self.session = session
        self.github = GitHubMarketplaceClient(session: session, token: githubToken)
        self.gitlab = GitLabMarketplaceClient(session: session)
        self.gitee = GiteeMarketplaceClient(session: session)
        self.npm = NpmMarketplaceClient(session: session)
        self.modelScope = ModelScopeMarketplaceClient(session: session)
        self.builtin = Self.loadBuiltin()
    }

    public func builtinItems() -> [MarketplaceItem] {
        builtin
    }

    public func feed(
        query: String,
        source: MarketplaceSource?,
        page: Int = 1,
        pageSize: Int = 20
    ) async -> MarketplaceResult {
        let key = "\(source?.rawValue ?? "all")|\(query.lowercased())|\(page)|\(pageSize)"
        if let cached = cache[key], Date().timeIntervalSince(cached.date) < 60 {
            return cached.result
        }

        var items: [MarketplaceItem] = []
        var errors: [String] = []
        var hasMore = false

        if page == 1, source == nil || source == .builtin {
            items.append(contentsOf: filterBuiltin(query))
        }
        if source == nil || source == .github {
            do {
                let list = try await github.searchRepositories(
                    query: query,
                    page: page,
                    perPage: pageSize
                )
                items.append(contentsOf: list)
                if list.count >= pageSize { hasMore = true }
            } catch {
                errors.append("GitHub: \(error.localizedDescription)")
            }
        }
        if source == nil || source == .modelScope {
            do {
                let list = try await modelScope.search(
                    query: query,
                    page: page,
                    pageSize: pageSize
                )
                items.append(contentsOf: list)
                if list.count >= pageSize { hasMore = true }
            } catch {
                errors.append("魔搭: \(error.localizedDescription)")
            }
        }

        let merged = Self.dedupe(items).sorted(by: Self.order)
        let result = MarketplaceResult(items: merged, errors: errors, hasMore: hasMore)
        cache[key] = (Date(), result)
        return result
    }

    /// 展开 GitHub 插件市场仓库(Claude `marketplace.json`)为子插件卡片。
    public func expand(item: MarketplaceItem) async throws -> [MarketplaceItem] {
        guard let raw = item.installURL,
              let link = MarketplaceLinkParser.parse(raw),
              case let .github(owner, repo, ref) = link
        else {
            throw MarketplaceError.unsupportedSource("仅支持 GitHub 插件市场目录")
        }
        let key = "\(owner)/\(repo)@\(ref ?? "HEAD")"
        if let cached = expansions[key] { return cached }
        guard let market = try await github.marketplace(owner: owner, repo: repo, ref: ref) else {
            throw MarketplaceError.invalidPackage("该仓库没有 .claude-plugin/marketplace.json 或 marketplace.json")
        }
        let baseURL = "https://github.com/\(owner)/\(repo)"
        var items: [MarketplaceItem] = []
        for entry in market.plugins {
            switch entry.source {
            case .relative(let path):
                let normalized = Self.normalizePath(path)
                items.append(
                    MarketplaceItem(
                        id: "github:\(owner)/\(repo)/\(MarketplaceInstaller.sanitize(entry.name))",
                        name: entry.name,
                        summary: entry.description,
                        author: owner,
                        version: entry.version,
                        source: .github,
                        kind: .plugin,
                        tags: entry.tags,
                        homepage: baseURL,
                        installURL: baseURL,
                        installPath: normalized.isEmpty ? nil : normalized
                    )
                )
            case let .github(repoPath, ref, _):
                let parts = repoPath.split(separator: "/")
                guard parts.count >= 2 else { continue }
                let repoURL = "https://github.com/\(repoPath)"
                items.append(
                    MarketplaceItem(
                        id: "github:\(repoPath)/\(MarketplaceInstaller.sanitize(entry.name))",
                        name: entry.name,
                        summary: entry.description,
                        author: String(parts[0]),
                        version: entry.version,
                        source: .github,
                        kind: .plugin,
                        tags: entry.tags,
                        homepage: repoURL,
                        installURL: ref.map { "\(repoURL)/tree/\($0)" } ?? repoURL
                    )
                )
            case let .gitSubdir(repoPath, _, path):
                let parts = repoPath.split(separator: "/")
                guard parts.count >= 2 else { continue }
                let repoURL = "https://github.com/\(repoPath)"
                items.append(
                    MarketplaceItem(
                        id: "github:\(repoPath)/\(MarketplaceInstaller.sanitize(entry.name))",
                        name: entry.name,
                        summary: entry.description,
                        author: String(parts[0]),
                        version: entry.version,
                        source: .github,
                        kind: .plugin,
                        tags: entry.tags,
                        homepage: repoURL,
                        installURL: repoURL,
                        installPath: Self.normalizePath(path)
                    )
                )
            case .archive, .npm, .command:
                // 首版不自动安装 npm/archive/command 源,避免执行未知脚本。
                continue
            }
        }
        guard !items.isEmpty else {
            throw MarketplaceError.invalidPackage("市场清单中没有可自动安装的插件")
        }
        expansions[key] = items
        return items
    }

    private static func normalizePath(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("./") {
            text.removeFirst(2)
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func importLink(_ raw: String) async throws -> MarketplaceItem {
        guard let link = MarketplaceLinkParser.parse(raw) else {
            throw MarketplaceError.invalidLink(raw)
        }
        switch link {
        case let .github(owner, repo, ref):
            let repository = try await github.repository(owner: owner, repo: repo)
            let subpath = MarketplaceLinkParser.installPath(raw)
            let url = ref.map { "https://github.com/\(owner)/\(repo)/tree/\($0)" }
                ?? "https://github.com/\(owner)/\(repo)"
            let name = subpath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? repo
            return MarketplaceItem(
                id: "github:\(owner)/\(repo)".lowercased()
                    + (subpath.map { "#\($0)" } ?? ""),
                name: name,
                summary: repository.description,
                author: owner,
                source: .github,
                kind: repository.description.localizedCaseInsensitiveContains("mcp") ? .mcp : .skill,
                tags: [],
                stars: repository.stars,
                license: repository.license,
                homepage: repository.htmlURL,
                installURL: url,
                iconURL: repository.avatarURL,
                installPath: subpath
            )
        case .modelScopeSkill:
            guard let item = try await modelScope.resolve(link: link) else {
                throw MarketplaceError.invalidLink(raw)
            }
            return item
        case .modelScopeModel:
            throw MarketplaceError.unsupportedSource("ModelScope 模型页暂不支持作为技能安装")
        case let .gitLab(owner, repo, ref):
            let repository = try await gitlab.repository(owner: owner, repo: repo)
            let url = ref.map { "https://gitlab.com/\(owner)/\(repo)/-/tree/\($0)" }
                ?? "https://gitlab.com/\(owner)/\(repo)"
            return MarketplaceItem(
                id: "gitlab:\(owner)/\(repo)".lowercased(),
                name: repo,
                summary: repository.description,
                author: owner,
                source: .gitLab,
                kind: .plugin,
                stars: repository.stars,
                homepage: repository.htmlURL,
                installURL: url,
                iconURL: repository.avatarURL
            )
        case let .gitee(owner, repo, ref):
            let repository = try await gitee.repository(owner: owner, repo: repo)
            let url = ref.map { "https://gitee.com/\(owner)/\(repo)/tree/\($0)" }
                ?? "https://gitee.com/\(owner)/\(repo)"
            return MarketplaceItem(
                id: "gitee:\(owner)/\(repo)".lowercased(),
                name: repo,
                summary: repository.description,
                author: owner,
                source: .gitee,
                kind: .plugin,
                stars: repository.stars,
                homepage: repository.htmlURL,
                installURL: url,
                iconURL: repository.avatarURL
            )
        case .npm(let package):
            let repository = try await npm.repository(package: package)
            return MarketplaceItem(
                id: "npm:\(package)",
                name: package,
                summary: repository.description,
                author: repository.fullName.hasPrefix("npm") ? "" : repository.fullName,
                source: .npm,
                kind: .plugin,
                license: repository.license,
                homepage: repository.htmlURL,
                installURL: "https://www.npmjs.com/package/\(package)"
            )
        case .hivePlugin(let url):
            guard let requestURL = URL(string: url) else {
                throw MarketplaceError.invalidLink(raw)
            }
            let (data, response) = try await session.data(from: requestURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                throw MarketplaceError.http(
                    (response as? HTTPURLResponse)?.statusCode ?? 0,
                    "无法下载插件包"
                )
            }
            guard let bundle = try? JSONDecoder().decode(PluginBundle.self, from: data),
                  !bundle.manifest.skills.isEmpty || !bundle.manifest.mcpServers.isEmpty
            else {
                throw MarketplaceError.invalidPackage("不是有效的 .hiveplugin.json 插件包")
            }
            return MarketplaceItem(
                id: "bundle:\(bundle.manifest.id)",
                name: bundle.manifest.name,
                summary: bundle.manifest.description,
                author: bundle.manifest.author,
                version: bundle.manifest.version,
                source: .web,
                kind: .plugin,
                tags: bundle.manifest.tags,
                license: bundle.manifest.license,
                installURL: url,
                pluginBundle: bundle
            )
        }
    }

    // MARK: - 内置目录

    private func filterBuiltin(_ query: String) -> [MarketplaceItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return builtin }
        return builtin.filter { item in
            item.name.lowercased().contains(trimmed)
                || item.summary.lowercased().contains(trimmed)
                || item.tags.contains { $0.lowercased().contains(trimmed) }
                || item.author.lowercased().contains(trimmed)
        }
    }

    private static func loadBuiltin() -> [MarketplaceItem] {
        guard let url = Bundle.module.url(forResource: "MarketplaceCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([MarketplaceItem].self, from: data)
        else { return [] }
        return items
    }

    // MARK: - 排序 / 去重

    private static func dedupe(_ items: [MarketplaceItem]) -> [MarketplaceItem] {
        var seen: [String: MarketplaceItem] = [:]
        for item in items {
            if let existing = seen[item.id] {
                // 保留信息更完整的一条
                if score(item) > score(existing) { seen[item.id] = item }
            } else {
                seen[item.id] = item
            }
        }
        return Array(seen.values)
    }

    private static func score(_ item: MarketplaceItem) -> Int {
        (item.summary.isEmpty ? 0 : 1)
            + (item.stars ?? 0)
            + (item.downloads ?? 0)
            + item.tags.count
    }

    private static func order(_ lhs: MarketplaceItem, _ rhs: MarketplaceItem) -> Bool {
        if lhs.source == .builtin, rhs.source != .builtin { return true }
        if rhs.source == .builtin, lhs.source != .builtin { return false }
        let lhsPopularity = (lhs.stars ?? 0) + (lhs.downloads ?? 0)
        let rhsPopularity = (rhs.stars ?? 0) + (rhs.downloads ?? 0)
        if lhsPopularity != rhsPopularity { return lhsPopularity > rhsPopularity }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
