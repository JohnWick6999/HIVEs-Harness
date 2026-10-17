import Foundation

public enum MarketplaceSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case builtin
    case github
    case modelScope
    case gitLab
    case gitee
    case npm
    case web

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .builtin: return "内置"
        case .github: return "GitHub"
        case .modelScope: return "魔搭"
        case .gitLab: return "GitLab"
        case .gitee: return "Gitee"
        case .npm: return "npm"
        case .web: return "直链"
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
    /// 插件在仓库内的子目录(如 plugins/pdf)
    public var installPath: String?
    /// 直链 `.hiveplugin.json` 的内嵌内容
    public var pluginBundle: PluginBundle?

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
        installCommand: String? = nil,
        installPath: String? = nil,
        pluginBundle: PluginBundle? = nil
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
        self.installPath = installPath
        self.pluginBundle = pluginBundle
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, author, version, source, kind, tags
        case stars, downloads, license, homepage, installURL, iconURL, installCommand, installPath
        case pluginBundle
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
        installPath = try container.decodeIfPresent(String.self, forKey: .installPath)
        pluginBundle = try container.decodeIfPresent(PluginBundle.self, forKey: .pluginBundle)
    }
}

public struct MarketplaceResult: Sendable {
    public var items: [MarketplaceItem]
    public var errors: [String]
    public var hasMore: Bool

    public init(
        items: [MarketplaceItem] = [],
        errors: [String] = [],
        hasMore: Bool = false
    ) {
        self.items = items
        self.errors = errors
        self.hasMore = hasMore
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
        if text.lowercased().hasPrefix("npm:") {
            let package = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            return package.isEmpty ? nil : .npm(package: package)
        }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased()
        else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        let lowerPath = components.path.lowercased()
        if lowerPath.hasSuffix(".hiveplugin") || lowerPath.hasSuffix(".hiveplugin.json") {
            return .hivePlugin(url: text)
        }

        if host == "github.com" || host == "www.github.com" {
            guard parts.count >= 2 else { return nil }
            let owner = parts[0]
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            var ref: String?
            if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
                ref = parts[3]
            }
            return .github(owner: owner, repo: repo, ref: ref)
        }

        // raw 文件链接:raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>
        if host == "raw.githubusercontent.com" {
            guard parts.count >= 4 else { return nil }
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            return .github(owner: parts[0], repo: repo, ref: parts[2])
        }

        if host == "gitlab.com" || host == "www.gitlab.com" {
            guard parts.count >= 2 else { return nil }
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            var ref: String?
            if parts.count >= 4, parts[2] == "-", parts[3] == "tree", parts.count >= 5 {
                ref = parts[4]
            }
            return .gitLab(owner: parts[0], repo: repo, ref: ref)
        }

        if host == "gitee.com" || host == "www.gitee.com" {
            guard parts.count >= 2 else { return nil }
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo.removeLast(4) }
            var ref: String?
            if parts.count >= 4, parts[2] == "tree" {
                ref = parts[3]
            }
            return .gitee(owner: parts[0], repo: repo, ref: ref)
        }

        if host == "npmjs.com" || host == "www.npmjs.com" {
            guard parts.count >= 2, parts[0] == "package" else { return nil }
            let package = parts.dropFirst().joined(separator: "/")
            return package.isEmpty ? nil : .npm(package: package)
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

    /// GitHub tree/blob/raw 链接中的子目录;文件链接返回其父目录。
    public static func installPath(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased()
        else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)

        if host == "github.com" || host == "www.github.com" {
            guard parts.count >= 3, parts[2] == "tree" || parts[2] == "blob" else { return nil }
            guard parts.count > 4 else { return nil }
            let path = parts.dropFirst(4).joined(separator: "/")
            return fileAwarePath(path)
        }
        if host == "raw.githubusercontent.com" {
            guard parts.count > 4 else { return nil }
            return fileAwarePath(parts.dropFirst(3).joined(separator: "/"))
        }
        return nil
    }

    private static func fileAwarePath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        let last = URL(fileURLWithPath: trimmed).lastPathComponent
        // plugin.json 在 .claude-plugin/ 下时,技能通常在仓库根
        if trimmed == ".claude-plugin/plugin.json" { return nil }
        if trimmed.hasSuffix("plugin.json") || trimmed.hasSuffix("marketplace.json") {
            return parentPath(trimmed)
        }
        if last.contains(".") {
            return parentPath(trimmed)
        }
        return trimmed
    }

    private static func parentPath(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }
}

public enum MarketplaceLink: Sendable, Equatable {
    case github(owner: String, repo: String, ref: String?)
    case modelScopeSkill(owner: String, name: String)
    case modelScopeModel(owner: String, name: String)
    case gitLab(owner: String, repo: String, ref: String?)
    case gitee(owner: String, repo: String, ref: String?)
    case npm(package: String)
    case hivePlugin(url: String)

    public var rawURL: String {
        switch self {
        case .github(let owner, let repo, _):
            return "https://github.com/\(owner)/\(repo)"
        case .modelScopeSkill(let owner, let name):
            return "https://modelscope.cn/skills/\(owner)/\(name)"
        case .modelScopeModel(let owner, let name):
            return "https://modelscope.cn/models/\(owner)/\(name)"
        case .gitLab(let owner, let repo, _):
            return "https://gitlab.com/\(owner)/\(repo)"
        case .gitee(let owner, let repo, _):
            return "https://gitee.com/\(owner)/\(repo)"
        case .npm(let package):
            return "https://www.npmjs.com/package/\(package)"
        case .hivePlugin(let url):
            return url
        }
    }
}
