import Foundation

public struct ModelScopeFile: Sendable, Equatable {
    public var path: String
    public var type: String
    public var size: Int
    public var sha256: String

    public init(path: String, type: String, size: Int, sha256: String = "") {
        self.path = path
        self.type = type
        self.size = size
        self.sha256 = sha256
    }
}

/// ModelScope(魔搭)技能市场客户端。
/// 使用其 JSON OpenAPI `/openapi/v1/skills`(支持 search / page_size)。
public struct ModelScopeMarketplaceClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func search(
        query: String,
        page: Int = 1,
        pageSize: Int = 24
    ) async throws -> [MarketplaceItem] {
        var components = URLComponents(string: "https://modelscope.cn/openapi/v1/skills")!
        var items = [
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "page_size", value: String(min(50, max(1, pageSize)))),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "search", value: trimmed))
        }
        components.queryItems = items

        let data = try await get(components.url!)
        return Self.parseItems(data)
    }

    /// 读取技能仓库文件列表。
    public func files(id: String) async throws -> [ModelScopeFile] {
        let encodedID = Self.encodedPath(id)
        let url = URL(string: "https://modelscope.cn/api/v1/skills/\(encodedID)/repo/files?Revision=master&Recursive=true")!
        let data = try await get(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["Data"] as? [String: Any],
              let files = payload["Files"] as? [[String: Any]]
        else { return [] }
        return files.compactMap { raw in
            guard let path = raw["Path"] as? String,
                  !path.isEmpty
            else { return nil }
            return ModelScopeFile(
                path: path,
                type: raw["Type"] as? String ?? "blob",
                size: raw["Size"] as? Int ?? 0,
                sha256: raw["Sha256"] as? String ?? ""
            )
        }
    }

    /// 读取技能仓库原始文件(优先 resolve 直链,失败后回退 repo/raw JSON)。
    public func rawFile(id: String, path: String) async throws -> String {
        let encodedID = Self.encodedPath(id)
        let encodedFile = Self.encodedPath(path)
        let direct = URL(string: "https://modelscope.cn/api/v1/skills/\(encodedID)/resolve/master/\(encodedFile)")!
        if let data = try? await get(direct),
           let text = String(data: data, encoding: .utf8),
           !text.hasPrefix("{\"Code\"") {
            return text
        }
        let fallback = URL(string: "https://modelscope.cn/api/v1/skills/\(encodedID)/repo/raw?Revision=master&FilePath=\(encodedFile)")!
        let data = try await get(fallback)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["Data"] as? [String: Any],
              let content = payload["Content"] as? String
        else { return "" }
        return content
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("HiveHarness/0.1 (macOS Agent)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketplaceError.http(0, "非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MarketplaceError.http(http.statusCode, "ModelScope 请求失败")
        }
        return data
    }

    static func encodedPath(_ raw: String) -> String {
        raw.split(separator: "/").map { component in
            String(component).addingPercentEncoding(
                withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
            ) ?? String(component)
        }.joined(separator: "/")
    }


    /// 从链接导入:用 owner/name 搜索并选取最匹配的一项。
    public func resolve(link: MarketplaceLink) async throws -> MarketplaceItem? {
        guard case let .modelScopeSkill(owner, name) = link else {
            throw MarketplaceError.unsupportedSource("ModelScope 仅支持 skills 页面")
        }
        let results = try await search(query: name, page: 1, pageSize: 30)
        let target = "\(owner)/\(name)".lowercased()
        return results.first {
            $0.id.lowercased().contains(target)
                || $0.installURL?.lowercased().contains(target) == true
        } ?? results.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - 解析(兼容 data/list/skills/items 多种外壳)

    static func parseItems(_ data: Data) -> [MarketplaceItem] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let candidates = extractArray(from: object)
        return candidates.compactMap { marketplaceItem(from: $0) }
    }

    private static func extractArray(from object: Any) -> [[String: Any]] {
        if let array = object as? [[String: Any]] { return array }
        guard let root = object as? [String: Any] else { return [] }
        if let data = root["data"] {
            if let array = data as? [[String: Any]] { return array }
            if let dict = data as? [String: Any] {
                for key in ["skills", "list", "items", "records"] {
                    if let array = dict[key] as? [[String: Any]] { return array }
                }
            }
        }
        for key in ["items", "skills", "list"] {
            if let array = root[key] as? [[String: Any]] { return array }
        }
        return []
    }

    static func marketplaceItem(from raw: [String: Any]) -> MarketplaceItem? {
        let rawID = string(raw["id"]) ?? string(raw["skill_id"]) ?? string(raw["name"])
        guard let rawID, !rawID.isEmpty else { return nil }
        let fallbackName = rawID.split(separator: "/").last.map(String.init) ?? rawID
        let name = string(raw["display_name"]) ?? string(raw["name"]) ?? fallbackName
        let owner = ownerName(raw["owner"])
            ?? string(raw["author"])
            ?? string(raw["namespace"])
            ?? string(raw["user_name"])
            ?? rawID.split(separator: "/").first.map(String.init)
            ?? ""
        let summary = string(raw["description"])
            ?? string(raw["summary"])
            ?? String((string(raw["readme"]) ?? "").prefix(160))
        let license = licenseName(raw["license"])
        let tags = tagNames(raw["tags"]).map {
            $0.hasPrefix("category:") ? String($0.dropFirst("category:".count)) : $0
        }
        let installURL = string(raw["source_url"])
            ?? string(raw["url"])
            ?? "https://modelscope.cn/skills/\(rawID)"
        return MarketplaceItem(
            id: "modelscope:\(rawID)".lowercased(),
            name: name,
            summary: summary,
            author: owner,
            version: string(raw["version"]) ?? "",
            source: .modelScope,
            kind: .skill,
            tags: tags,
            stars: int(raw["stars"]) ?? int(raw["likes"]),
            downloads: int(raw["downloads"]) ?? int(raw["download_count"]) ?? int(raw["views"]),
            license: license,
            homepage: string(raw["homepage"]) ?? installURL,
            installURL: installURL,
            iconURL: string(raw["logo_url"]) ?? string(raw["avatar"]) ?? string(raw["icon"]),
            installCommand: string(raw["install_command"])
        )
    }

    // MARK: - 字段归一

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func ownerName(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let dict = value as? [String: Any] {
            return string(dict["name"]) ?? string(dict["login"]) ?? string(dict["nickname"])
        }
        return nil
    }

    private static func licenseName(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let dict = value as? [String: Any] {
            return string(dict["name"]) ?? string(dict["spdx_id"])
        }
        return nil
    }

    private static func tagNames(_ value: Any?) -> [String] {
        if let tags = value as? [String] { return Array(tags.prefix(6)) }
        if let tags = value as? [[String: Any]] {
            return Array(tags.compactMap { string($0["name"]) ?? string($0["label"]) }.prefix(6)).map { $0 }
        }
        if let text = value as? String {
            let items = text.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            return Array(items.prefix(6))
        }
        return []
    }
}
