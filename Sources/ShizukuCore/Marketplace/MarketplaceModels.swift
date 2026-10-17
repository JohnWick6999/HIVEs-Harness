import Foundation

public enum MarketplaceSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case builtin
    case github
    case modelScope

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .builtin: return "内置"
        case .github: return "GitHub"
        case .modelScope: return "魔搭"
        }
    }
}

public enum MarketplaceKind: String, Codable, Sendable, CaseIterable {
    case skill
    case mcp
    case plugin

    public var title: String {
        switch self {
        case .skill: return "技能"
        case .mcp: return "MCP"
        case .plugin: return "插件包"
        }
    }
}

/// 市场统一卡片:不同来源的清单都归一到这里。
public struct MarketplaceItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var author: String
    public var version: String
    public var source: MarketplaceSource
    public var kind: MarketplaceKind
    public var tags: [String]
    public var stars: Int?
    public var downloads: Int?
    public var license: String?
    public var homepage: String?
    /// 安装入口:GitHub 仓库或 ModelScope 页面
    public var installURL: String?
    public var iconURL: String?
    /// ModelScope 可能给出的安装命令(不自动执行)
    public var installCommand: String?

    public init(
        id: String,
        name: String,
        summary: String,
        author: String = "",
        version: String = "",
        source: MarketplaceSource,
        kind: MarketplaceKind = .skill,
        tags: [String] = [],
        stars: Int? = nil,
        downloads: Int? = nil,
        license: String? = nil,
        homepage: String? = nil,
        installURL: String? = nil,
        iconURL: String? = nil,
        installCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.author = author
        self.version = version
        self.source = source
        self.kind = kind
        self.tags = tags
        self.stars = stars
        self.downloads = downloads
        self.license = license
        self.homepage = homepage
        self.installURL = installURL
        self.iconURL = iconURL
        self.installCommand = installCommand
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, author, version, source, kind, tags
        case stars, downloads, license, homepage, installURL, iconURL, installCommand
    }

    /// 远程/内置清单字段不齐时使用默认值,避免整份目录解码失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        source = try container.decodeIfPresent(MarketplaceSource.self, forKey: .source) ?? .github
        kind = try container.decodeIfPresent(MarketplaceKind.self, forKey: .kind) ?? .skill
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        stars = try container.decodeIfPresent(Int.self, forKey: .stars)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        installURL = try container.decodeIfPresent(String.self, forKey: .installURL)
        iconURL = try container.decodeIfPresent(String.self, forKey: .iconURL)
        installCommand = try container.decodeIfPresent(String.self, forKey: .installCommand)
    }
}

public struct MarketplaceResult: Sendable {
    public var items: [MarketplaceItem]
    public var errors: [String]

    public init(items: [MarketplaceItem] = [], errors: [String] = []) {
        self.items = items
        self.errors = errors
    }
}

public enum MarketplaceError: Error, Sendable, Equatable {
    case invalidLink(String)
    case unsupportedSource(String)
    case http(Int, String)
    case rateLimited(String)
    case noInstallableSkill
    case invalidPackage(String)
}

extension MarketplaceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidLink(let raw): return "无法识别的链接: \(raw)"
        case .unsupportedSource(let source): return "暂不支持的市场来源: \(source)"
        case .http(let code, let message): return "请求失败(HTTP \(code)): \(message)"
        case .rateLimited(let message): return "GitHub 限流: \(message)"
        case .noInstallableSkill: return "没有找到可安装的 SKILL.md"
        case .invalidPackage(let message): return "插件包无效: \(message)"
        }
    }
}

/// GitHub / ModelScope 链接解析。
public enum MarketplaceLinkParser {
    public static func parse(_ raw: String) -> MarketplaceLink? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased()
        else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)

        if host == "github.com" || host == "www.github.com" {
            guard parts.count >= 2 else { return nil }
            let owner = parts[0]
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            var ref: String?
            if parts.count >= 4, parts[2] == "tree" {
                ref = parts[3]
            }
            return .github(owner: owner, repo: repo, ref: ref)
        }

        if host == "modelscope.cn" || host == "www.modelscope.cn" {
            guard parts.count >= 2 else { return nil }
            let section = parts[0]
            let owner = parts[1]
            let name = parts.count >= 3 ? parts[2] : owner
            switch section {
            case "skills":
                return .modelScopeSkill(owner: owner, name: name)
            case "models":
                return .modelScopeModel(owner: owner, name: name)
            default:
                return nil
            }
        }
        return nil
    }
}

public enum MarketplaceLink: Sendable, Equatable {
    case github(owner: String, repo: String, ref: String?)
    case modelScopeSkill(owner: String, name: String)
    case modelScopeModel(owner: String, name: String)

    public var rawURL: String {
        switch self {
        case .github(let owner, let repo, _):
            return "https://github.com/\(owner)/\(repo)"
        case .modelScopeSkill(let owner, let name):
            return "https://modelscope.cn/skills/\(owner)/\(name)"
        case .modelScopeModel(let owner, let name):
            return "https://modelscope.cn/models/\(owner)/\(name)"
        }
    }
}
