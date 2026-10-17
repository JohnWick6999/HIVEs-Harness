import Foundation

/// Claude Code / Agent Plugins 市场清单(只保留本应用需要的字段)。
public struct ClaudeMarketplace: Sendable, Equatable {
    public var name: String
    public var owner: String
    public var plugins: [ClaudePluginEntry]

    public init(name: String, owner: String = "", plugins: [ClaudePluginEntry] = []) {
        self.name = name
        self.owner = owner
        self.plugins = plugins
    }
}

public struct ClaudePluginEntry: Sendable, Equatable {
    public var name: String
    public var description: String
    public var version: String
    public var category: String
    public var tags: [String]
    public var source: ClaudePluginSource

    public init(
        name: String,
        description: String = "",
        version: String = "",
        category: String = "",
        tags: [String] = [],
        source: ClaudePluginSource
    ) {
        self.name = name
        self.description = description
        self.version = version
        self.category = category
        self.tags = tags
        self.source = source
    }
}

public enum ClaudePluginSource: Sendable, Equatable {
    case relative(String)
    case github(repo: String, ref: String?, sha: String?)
    case gitSubdir(repo: String, ref: String?, path: String)
    case archive(url: String, sha256: String?)
    case npm(package: String, version: String?)
    case command(String)
}

public enum ClaudeMarketplaceParser {
    public static func parse(_ data: Data) -> ClaudeMarketplace? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let name = root["name"] as? String ?? ""
        let owner: String
        if let dict = root["owner"] as? [String: Any] {
            owner = dict["name"] as? String ?? ""
        } else {
            owner = root["owner"] as? String ?? ""
        }
        let rawPlugins = root["plugins"] as? [[String: Any]] ?? []
        let entries = rawPlugins.compactMap(parseEntry)
        guard !entries.isEmpty else { return nil }
        return ClaudeMarketplace(name: name, owner: owner, plugins: entries)
    }

    static func parseEntry(_ raw: [String: Any]) -> ClaudePluginEntry? {
        guard let name = raw["name"] as? String, !name.isEmpty,
              let source = parseSource(raw["source"])
        else { return nil }
        let tags = (raw["tags"] as? [String]) ?? []
        let category = raw["category"] as? String ?? ""
        return ClaudePluginEntry(
            name: name,
            description: raw["description"] as? String ?? "",
            version: raw["version"] as? String ?? "",
            category: category,
            tags: tags,
            source: source
        )
    }

    static func parseSource(_ raw: Any?) -> ClaudePluginSource? {
        if let text = raw as? String, !text.isEmpty {
            return .relative(text)
        }
        guard let dict = raw as? [String: Any] else { return nil }
        let kind = dict["source"] as? String ?? ""
        switch kind {
        case "github":
            guard let repo = dict["repo"] as? String, !repo.isEmpty else { return nil }
            return .github(
                repo: repo,
                ref: dict["ref"] as? String,
                sha: dict["sha"] as? String
            )
        case "git-subdir":
            guard let repo = dict["repo"] as? String,
                  let path = dict["path"] as? String
            else { return nil }
            return .gitSubdir(
                repo: repo,
                ref: dict["ref"] as? String,
                path: path
            )
        case "archive":
            guard let url = dict["url"] as? String else { return nil }
            return .archive(url: url, sha256: dict["sha256"] as? String)
        case "npm":
            guard let package = dict["package"] as? String else { return nil }
            return .npm(package: package, version: dict["version"] as? String)
        case "command":
            guard let command = dict["command"] as? String else { return nil }
            return .command(command)
        default:
            return nil
        }
    }
}
