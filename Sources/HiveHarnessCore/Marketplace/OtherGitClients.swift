import Foundation

/// GitLab 公开 API 适配器(只读,支持 repo/tree/raw)。
public struct GitLabMarketplaceClient: Sendable {
    private let session: URLSession
    private let token: String?

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func repository(owner: String, repo: String) async throws -> GitHubRepository {
        let project = Self.encodeProject(owner: owner, repo: repo)
        let data = try await get("https://gitlab.com/api/v4/projects/\(project)")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MarketplaceError.http(200, "GitLab 仓库信息解析失败")
        }
        return GitHubRepository(
            owner: owner,
            name: repo,
            fullName: "\(owner)/\(repo)",
            description: object["description"] as? String ?? "",
            stars: object["star_count"] as? Int ?? 0,
            license: nil,
            defaultBranch: object["default_branch"] as? String ?? "main",
            htmlURL: object["web_url"] as? String ?? "https://gitlab.com/\(owner)/\(repo)",
            avatarURL: object["avatar_url"] as? String
        )
    }

    public func tree(owner: String, repo: String, ref: String) async throws -> [GitHubTreeEntry] {
        let project = Self.encodeProject(owner: owner, repo: repo)
        let refEncoded = Self.encodeSegment(ref)
        let url = "https://gitlab.com/api/v4/projects/\(project)/repository/tree?ref=\(refEncoded)&recursive=true&per_page=100"
        let data = try await get(url)
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { raw in
            guard let path = raw["path"] as? String,
                  let type = raw["type"] as? String
            else { return nil }
            return GitHubTreeEntry(
                path: path,
                type: type == "tree" ? "tree" : "blob",
                size: nil,
                sha: nil
            )
        }
    }

    public func rawFile(owner: String, repo: String, ref: String, path: String) async throws -> String {
        let project = Self.encodeProject(owner: owner, repo: repo)
        let encodedPath = path.split(separator: "/").map { Self.encodeSegment(String($0)) }.joined(separator: "%2F")
        let refEncoded = Self.encodeSegment(ref)
        let url = "https://gitlab.com/api/v4/projects/\(project)/repository/files/\(encodedPath)/raw?ref=\(refEncoded)"
        let data = try await get(url)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func get(_ raw: String) async throws -> Data {
        guard let url = URL(string: raw) else {
            throw MarketplaceError.http(0, "GitLab URL 无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("HiveHarness/0.1 (macOS Agent)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw MarketplaceError.http(
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                "GitLab 请求失败"
            )
        }
        return data
    }

    private static func encodeProject(owner: String, repo: String) -> String {
        "\(owner)/\(repo)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "\(owner)%2F\(repo)"
    }

    private static func encodeSegment(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw
    }
}

/// Gitee 公开 API 适配器(只读,支持 repo/tree/raw)。
public struct GiteeMarketplaceClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func repository(owner: String, repo: String) async throws -> GitHubRepository {
        let data = try await get("https://gitee.com/api/v5/repos/\(owner)/\(repo)")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MarketplaceError.http(200, "Gitee 仓库信息解析失败")
        }
        return GitHubRepository(
            owner: owner,
            name: repo,
            fullName: "\(owner)/\(repo)",
            description: object["description"] as? String ?? "",
            stars: object["stargazers_count"] as? Int ?? 0,
            license: nil,
            defaultBranch: object["default_branch"] as? String ?? "master",
            htmlURL: object["html_url"] as? String ?? "https://gitee.com/\(owner)/\(repo)",
            avatarURL: object["avatar_url"] as? String
        )
    }

    public func tree(owner: String, repo: String, ref: String) async throws -> [GitHubTreeEntry] {
        let refEncoded = ref.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ref
        let data = try await get("https://gitee.com/api/v5/repos/\(owner)/\(repo)/git/trees/\(refEncoded)?recursive=1")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = object["tree"] as? [[String: Any]]
        else { return [] }
        return tree.compactMap { raw in
            guard let path = raw["path"] as? String,
                  let type = raw["type"] as? String
            else { return nil }
            return GitHubTreeEntry(
                path: path,
                type: type == "tree" ? "tree" : "blob",
                size: raw["size"] as? Int,
                sha: raw["sha"] as? String
            )
        }
    }

    public func rawFile(owner: String, repo: String, ref: String, path: String) async throws -> String {
        let encodedPath = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let refEncoded = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
        let data = try await get("https://gitee.com/\(owner)/\(repo)/raw/\(refEncoded)/\(encodedPath)")
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func get(_ raw: String) async throws -> Data {
        guard let url = URL(string: raw) else {
            throw MarketplaceError.http(0, "Gitee URL 无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("HiveHarness/0.1 (macOS Agent)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw MarketplaceError.http(
                (response as? HTTPURLResponse)?.statusCode ?? 0,
                "Gitee 请求失败"
            )
        }
        return data
    }
}
