import Foundation

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

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        request.setValue("ShizukuClaw/0.1 (macOS Agent)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarketplaceError.http(0, "非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MarketplaceError.http(http.statusCode, "ModelScope 请求失败")
        }
        return Self.parseItems(data)
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
        let name = string(raw["display_name"]) ?? string(raw["name"]) ?? rawID
        let owner = ownerName(raw["owner"])
            ?? string(raw["author"])
            ?? string(raw["namespace"])
            ?? string(raw["user_name"])
            ?? ""
        let summary = string(raw["description"])
            ?? string(raw["summary"])
            ?? String((string(raw["readme"]) ?? "").prefix(160))
        let license = licenseName(raw["license"])
        let tags = tagNames(raw["tags"])
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
            iconURL: string(raw["avatar"]) ?? string(raw["icon"]),
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
