import Foundation

/// HIVE 插件清单。兼容 HIVE / Claude `.claude-plugin/plugin.json` / Agent Plugins
/// 的常见字段;不执行插件代码,只声明 skills 与 MCP。
public struct PluginManifest: Codable, Sendable, Equatable, Identifiable {
    public var schema: String
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var author: String
    public var homepage: String
    public var license: String
    public var tags: [String]
    /// 相对插件根目录的 SKILL.md 路径;为空时自动发现 skills/**/SKILL.md。
    public var skills: [String]
    /// 内联 MCP 服务器;也兼容 Claude 的 mcpServers 键。
    public var mcpServers: [MCPServerConfig]
    /// Claude commands(仅展示/兼容,首版不执行)。
    public var commands: [String]
    /// Claude hooks(仅展示/兼容,首版不执行)。
    public var hooks: [String]

    public init(
        schema: String = "hive.plugin/v1",
        id: String,
        name: String,
        version: String = "0.1.0",
        description: String = "",
        author: String = "",
        homepage: String = "",
        license: String = "",
        tags: [String] = [],
        skills: [String] = [],
        mcpServers: [MCPServerConfig] = [],
        commands: [String] = [],
        hooks: [String] = []
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.homepage = homepage
        self.license = license
        self.tags = tags
        self.skills = skills
        self.mcpServers = mcpServers
        self.commands = commands
        self.hooks = hooks
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, name, version, description, author, homepage, license, tags
        case skills, mcpServers, commands, hooks
    }

    private enum AlternateKeys: String, CodingKey {
        case mcp_servers, manifest_version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternate = try decoder.container(keyedBy: AlternateKeys.self)
        schema = (try? container.decode(String.self, forKey: .schema))
            ?? (try? alternate.decode(String.self, forKey: .manifest_version))
            ?? "hive.plugin/v1"
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        version = (try? container.decode(String.self, forKey: .version)) ?? "0.1.0"
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        author = Self.decodeAuthor(container) ?? ""
        homepage = (try? container.decode(String.self, forKey: .homepage)) ?? ""
        license = (try? container.decode(String.self, forKey: .license)) ?? ""
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        skills = Self.decodeSkills(container)
        mcpServers = Self.decodeMCP(container, alternate: alternate)
        commands = Self.decodePathList(container, key: .commands)
        hooks = Self.decodePathList(container, key: .hooks)

        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            id = Self.slug(name.isEmpty ? "plugin" : name)
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(description, forKey: .description)
        try container.encode(author, forKey: .author)
        try container.encode(homepage, forKey: .homepage)
        try container.encode(license, forKey: .license)
        try container.encode(tags, forKey: .tags)
        try container.encode(skills, forKey: .skills)
        try container.encode(mcpServers, forKey: .mcpServers)
        try container.encode(commands, forKey: .commands)
        try container.encode(hooks, forKey: .hooks)
    }

    private static func decodeAuthor(_ container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let text = try? container.decode(String.self, forKey: .author) { return text }
        if let dict = try? container.decode([String: String].self, forKey: .author) {
            return dict["name"] ?? dict["url"]
        }
        return nil
    }

    private static func decodeSkills(_ container: KeyedDecodingContainer<CodingKeys>) -> [String] {
        if let text = try? container.decode(String.self, forKey: .skills) {
            return text.isEmpty ? [] : [text]
        }
        if let list = try? container.decode([String].self, forKey: .skills) {
            return list
        }
        if let list = try? container.decode([[String: String]].self, forKey: .skills) {
            return list.compactMap { $0["path"] ?? $0["source"] }
        }
        return []
    }

    private static func decodePathList(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> [String] {
        if let text = try? container.decode(String.self, forKey: key) {
            return text.isEmpty ? [] : [text]
        }
        if let list = try? container.decode([String].self, forKey: key) {
            return list
        }
        if let list = try? container.decode([[String: String]].self, forKey: key) {
            return list.compactMap { $0["path"] ?? $0["name"] }
        }
        return []
    }

    private static func decodeMCP(
        _ container: KeyedDecodingContainer<CodingKeys>,
        alternate: KeyedDecodingContainer<AlternateKeys>
    ) -> [MCPServerConfig] {
        // HIVE 数组
        if let list = try? container.decode([MCPServerConfig].self, forKey: .mcpServers) {
            return list
        }
        // Claude / VS Code 对象
        if let dict = try? container.decode([String: MCPServerConfig].self, forKey: .mcpServers) {
            return dict.map { key, value in
                var config = value
                if config.id.isEmpty || config.id == config.name {
                    config.id = key
                }
                if config.name.isEmpty { config.name = key }
                return config
            }
        }
        if let list = try? alternate.decode([MCPServerConfig].self, forKey: .mcp_servers) {
            return list
        }
        return []
    }

    private static func slug(_ raw: String) -> String {
        var result = ""
        for character in raw.lowercased() {
            if (character.isASCII && character.isLetter)
                || (character.isASCII && character.isNumber)
                || character == "-" || character == "_" || character == "." {
                result.append(character)
            } else {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return result.isEmpty ? "plugin" : String(result.prefix(60))
    }
}

public enum PluginTemplate: String, CaseIterable, Sendable, Identifiable {
    case skillPack
    case mcpBridge
    case hybrid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .skillPack: return "技能包"
        case .mcpBridge: return "MCP 连接器"
        case .hybrid: return "技能 + MCP"
        }
    }

    public var detail: String {
        switch self {
        case .skillPack: return "一个或多个 SKILL.md,适合可复用的工作流程。"
        case .mcpBridge: return "声明 MCP 服务器,默认停用,审查后启用。"
        case .hybrid: return "技能 + MCP 的组合插件。"
        }
    }
}

public struct PluginProject: Sendable, Identifiable, Equatable {
    public var manifest: PluginManifest
    public var root: URL
    public var files: [String]

    public var id: String { manifest.id }

    public init(manifest: PluginManifest, root: URL, files: [String]) {
        self.manifest = manifest
        self.root = root
        self.files = files
    }
}

public enum PluginIssueSeverity: String, Sendable, Equatable {
    case error
    case warning
    case info
}

public struct PluginValidationIssue: Sendable, Equatable, Identifiable {
    public var id: String { "\(severity.rawValue)-\(path)-\(message)" }
    public var severity: PluginIssueSeverity
    public var path: String
    public var message: String

    public init(severity: PluginIssueSeverity, path: String = "", message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

public struct PluginValidationReport: Sendable, Equatable {
    public var issues: [PluginValidationIssue]

    public init(issues: [PluginValidationIssue] = []) {
        self.issues = issues
    }

    public var errors: [PluginValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [PluginValidationIssue] { issues.filter { $0.severity == .warning } }
    public var canInstall: Bool { errors.isEmpty }
}

/// 可导出的单文件插件包(JSON + 内嵌文本文件),不依赖 zip。
public struct PluginBundle: Codable, Sendable, Equatable {
    public var schema: String
    public var manifest: PluginManifest
    public var files: [String: String]

    public init(
        schema: String = "hive.plugin.bundle/v1",
        manifest: PluginManifest,
        files: [String: String]
    ) {
        self.schema = schema
        self.manifest = manifest
        self.files = files
    }
}

/// 兼容层:识别 HIVE / Claude / 通用 plugin.json。
public enum PluginManifestParser {
    public static func parse(_ data: Data) -> PluginManifest? {
        guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            return nil
        }
        // Claude 插件常省略 skills 字段,由目录自动发现;
        // 只要 name/id 可识别就接受,具体内容由工坊校验。
        guard !manifest.id.isEmpty || !manifest.name.isEmpty else { return nil }
        return manifest
    }

    public static func manifestPath(in files: [String]) -> String? {
        let candidates = [
            "plugin.json",
            ".claude-plugin/plugin.json",
            ".hive-plugin/plugin.json",
        ]
        for candidate in candidates where files.contains(candidate) {
            return candidate
        }
        return files.first { $0.hasSuffix("/plugin.json") }
    }
}
