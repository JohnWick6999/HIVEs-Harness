import Foundation

/// 市场聚合服务:内置目录 + GitHub + ModelScope,统一去重排序并短时缓存。
public actor MarketplaceService {
    private let github: GitHubMarketplaceClient
    private let modelScope: ModelScopeMarketplaceClient
    private let builtin: [MarketplaceItem]
    private var cache: [String: (date: Date, result: MarketplaceResult)] = [:]

    public init(githubToken: String? = nil, session: URLSession = .shared) {
        self.github = GitHubMarketplaceClient(session: session, token: githubToken)
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

    public func importLink(_ raw: String) async throws -> MarketplaceItem {
        guard let link = MarketplaceLinkParser.parse(raw) else {
            throw MarketplaceError.invalidLink(raw)
        }
        switch link {
        case let .github(owner, repo, ref):
            let repository = try await github.repository(owner: owner, repo: repo)
            let url = ref.map { "https://github.com/\(owner)/\(repo)/tree/\($0)" }
                ?? "https://github.com/\(owner)/\(repo)"
            return MarketplaceItem(
                id: "github:\(owner)/\(repo)".lowercased(),
                name: repo,
                summary: repository.description,
                author: owner,
                source: .github,
                kind: repository.description.localizedCaseInsensitiveContains("mcp") ? .mcp : .skill,
                tags: [],
                stars: repository.stars,
                license: repository.license,
                homepage: repository.htmlURL,
                installURL: url,
                iconURL: repository.avatarURL
            )
        case .modelScopeSkill:
            guard let item = try await modelScope.resolve(link: link) else {
                throw MarketplaceError.invalidLink(raw)
            }
            return item
        case .modelScopeModel:
            throw MarketplaceError.unsupportedSource("ModelScope 模型页暂不支持作为技能安装")
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
