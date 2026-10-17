import Foundation

/// npm 声明式插件适配器:通过 unpkg 读取 package.json / 文件列表 / 文件内容。
/// 不执行 npm install、不运行 postinstall。
public struct NpmMarketplaceClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func repository(package: String) async throws -> GitHubRepository {
        let encoded = Self.packagePath(package)
        let data = try await get("https://unpkg.com/\(encoded)@latest/package.json")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MarketplaceError.http(200, "npm package.json 解析失败")
        }
        let author: String
        if let text = object["author"] as? String {
            author = text
        } else if let dict = object["author"] as? [String: Any] {
            author = dict["name"] as? String ?? ""
        } else {
            author = ""
        }
        return GitHubRepository(
            owner: "npm",
            name: package,
            fullName: package,
            description: object["description"] as? String ?? "",
            stars: 0,
            license: object["license"] as? String,
            defaultBranch: "latest",
            htmlURL: "https://www.npmjs.com/package/\(package)",
            avatarURL: nil
        )
    }

    public func tree(package: String) async throws -> [GitHubTreeEntry] {
        let encoded = Self.packagePath(package)
        let data = try await get("https://unpkg.com/\(encoded)@latest/?meta")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [[String: Any]]
        else { return [] }
        return files.compactMap { raw in
            guard let path = raw["path"] as? String else { return nil }
            let type = raw["type"] as? String ?? "file"
            return GitHubTreeEntry(
                path: path,
                type: type == "directory" ? "tree" : "blob",
                size: raw["size"] as? Int,
                sha: nil
            )
        }
    }

    public func rawFile(package: String, path: String) async throws -> String {
        let encoded = Self.packagePath(package)
        let encodedPath = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let data = try await get("https://unpkg.com/\(encoded)@latest/\(encodedPath)")
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func get(_ raw: String) async throws -> Data {
        guard let url = URL(string: raw) else {
            throw MarketplaceError.http(0, "npm URL 无效")
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
                "npm/unpkg 请求失败"
            )
        }
        return data
    }

    private static func packagePath(_ package: String) -> String {
        package.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }
}
