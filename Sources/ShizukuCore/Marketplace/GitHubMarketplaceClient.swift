import Foundation

public struct GitHubRepository: Sendable, Equatable {
    public var owner: String
    public var name: String
    public var fullName: String
    public var description: String
    public var stars: Int
    public var license: String?
    public var defaultBranch: String
    public var htmlURL: String
    public var avatarURL: String?

    public init(
        owner: String,
        name: String,
        fullName: String,
        description: String,
        stars: Int,
        license: String?,
        defaultBranch: String,
        htmlURL: String,
        avatarURL: String?
    ) {
        self.owner = owner
        self.name = name
        self.fullName = fullName
        self.description = description
        self.stars = stars
        self.license = license
        self.defaultBranch = defaultBranch
        self.htmlURL = htmlURL
        self.avatarURL = avatarURL
    }
}

public struct GitHubTreeEntry: Sendable, Equatable {
    public var path: String
    public var type: String
    public var size: Int?
    public var sha: String?

    public init(path: String, type: String, size: Int? = nil, sha: String? = nil) {
        self.path = path
        self.type = type
        self.size = size
        self.sha = sha
    }
}

/// GitHub 公开 API 客户端(未认证 60 次/时,建议在设置中填 Token)。
public struct GitHubMarketplaceClient: Sendable {
    private let session: URLSession
    private let token: String?

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func repository(owner: String, repo: String) async throws -> GitHubRepository {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!
        let (data, _) = try await request(url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MarketplaceError.http(200, "无法解析仓库信息")
        }
        return Self.repository(from: object)
    }

    public func tree(owner: String, repo: String, ref: String) async throws -> [GitHubTreeEntry] {
        var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/git/trees/\(ref)")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        let (data, _) = try await request(components.url!)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = object["tree"] as? [[String: Any]]
        else { return [] }
        return tree.compactMap { raw in
            guard let path = raw["path"] as? String,
                  let type = raw["type"] as? String
            else { return nil }
            return GitHubTreeEntry(
                path: path,
                type: type,
                size: raw["size"] as? Int,
                sha: raw["sha"] as? String
            )
        }
    }

    public func rawFile(owner: String, repo: String, ref: String, path: String) async throws -> String {
        let encodedPath = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(encodedPath)")!
        let (data, _) = try await request(url, api: false)
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func searchRepositories(
        query: String,
        page: Int = 1,
        perPage: Int = 20
    ) async throws -> [MarketplaceItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = trimmed.isEmpty
            ? "topic:claude-skills"
            : "\(trimmed) topic:claude-skills"
        var components = URLComponents(string: "https://api.github.com/search/repositories")!
        components.queryItems = [
            URLQueryItem(name: "q", value: terms),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "per_page", value: String(min(50, max(1, perPage)))),
        ]
        let (data, _) = try await request(components.url!)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { Self.marketplaceItem(from: $0) }
    }

    // MARK: - 请求

    private func request(_ url: URL, api: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("ShizukuClaw/0.1 (macOS Agent)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if api {
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketplaceError.http(0, "非 HTTP 响应")
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset") ?? ""
                throw MarketplaceError.rateLimited("配额已用尽,重置时间戳 \(reset)")
            }
            throw MarketplaceError.http(http.statusCode, "GitHub 拒绝请求")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MarketplaceError.http(http.statusCode, String(body.prefix(300)))
        }
        return (data, http)
    }

    // MARK: - 映射

    static func repository(from raw: [String: Any]) -> GitHubRepository {
        let owner = (raw["owner"] as? [String: Any])?["login"] as? String ?? ""
        let name = raw["name"] as? String ?? ""
        let license = (raw["license"] as? [String: Any])?["spdx_id"] as? String
        return GitHubRepository(
            owner: owner,
            name: name,
            fullName: raw["full_name"] as? String ?? "\(owner)/\(name)",
            description: raw["description"] as? String ?? "",
            stars: raw["stargazers_count"] as? Int ?? 0,
            license: license == "NOASSERTION" ? nil : license,
            defaultBranch: raw["default_branch"] as? String ?? "main",
            htmlURL: raw["html_url"] as? String ?? "https://github.com/\(owner)/\(name)",
            avatarURL: (raw["owner"] as? [String: Any])?["avatar_url"] as? String
        )
    }

    static func marketplaceItem(from raw: [String: Any]) -> MarketplaceItem? {
        let owner = (raw["owner"] as? [String: Any])?["login"] as? String ?? ""
        let name = raw["name"] as? String ?? ""
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        let description = raw["description"] as? String ?? ""
        let license = (raw["license"] as? [String: Any])?["spdx_id"] as? String
        let topics = raw["topics"] as? [String] ?? []
        return MarketplaceItem(
            id: "github:\(owner)/\(name)".lowercased(),
            name: name,
            summary: description,
            author: owner,
            source: .github,
            kind: description.localizedCaseInsensitiveContains("mcp") ? .mcp : .skill,
            tags: Array(topics.prefix(5)),
            stars: raw["stargazers_count"] as? Int,
            license: license == "NOASSERTION" ? nil : license,
            homepage: raw["html_url"] as? String,
            installURL: "https://github.com/\(owner)/\(name)",
            iconURL: (raw["owner"] as? [String: Any])?["avatar_url"] as? String
        )
    }
}
