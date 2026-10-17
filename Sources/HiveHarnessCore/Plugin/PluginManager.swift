import Foundation

/// 插件安全策略(对齐原版 plugin.json policy 字段)。
public struct PluginPolicy: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// 是否允许网络访问
    public var allowNetwork: Bool
    /// 单次执行最大耗时(毫秒)
    public var maxExecutionMs: Int
    /// 允许访问的域名白名单
    public var allowedDomains: [String]
    /// 允许执行的命令白名单
    public var allowedCommands: [String]

    public init(
        enabled: Bool = true,
        allowNetwork: Bool = false,
        maxExecutionMs: Int = 10_000,
        allowedDomains: [String] = [],
        allowedCommands: [String] = []
    ) {
        self.enabled = enabled
        self.allowNetwork = allowNetwork
        self.maxExecutionMs = maxExecutionMs
        self.allowedDomains = allowedDomains
        self.allowedCommands = allowedCommands
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case allowNetwork = "allow_network"
        case maxExecutionMs = "max_execution_ms"
        case allowedDomains = "allowed_domains"
        case allowedCommands = "allowed_commands"
    }

    /// 容错解码:缺失字段回退默认值(对齐原版 _default_policy 的宽松合并)。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        allowNetwork = try container.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? false
        maxExecutionMs = try container.decodeIfPresent(Int.self, forKey: .maxExecutionMs) ?? 10_000
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains) ?? []
        allowedCommands = try container.decodeIfPresent([String].self, forKey: .allowedCommands) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(allowNetwork, forKey: .allowNetwork)
        try container.encode(maxExecutionMs, forKey: .maxExecutionMs)
        try container.encode(allowedDomains, forKey: .allowedDomains)
        try container.encode(allowedCommands, forKey: .allowedCommands)
    }
}

/// 插件元数据(对齐原版 plugin.json)。
public struct PluginMeta: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var author: String
    public var dependencies: [String]
    /// 插件目录(相对插件根)
    public var projectPath: String
    public var hooks: [String]
    public var policy: PluginPolicy

    public init(
        id: String,
        name: String,
        version: String = "0.1.0",
        description: String = "",
        author: String = "",
        dependencies: [String] = [],
        projectPath: String = "",
        hooks: [String] = [],
        policy: PluginPolicy = PluginPolicy()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.dependencies = dependencies
        self.projectPath = projectPath
        self.hooks = hooks
        self.policy = policy
    }
}

public enum PluginError: Error, Sendable, Equatable {
    case notFound(String)
}

/// 插件管理器:扫描插件目录中的 plugin.json,维护元数据与策略(对齐原版 plugin_manager)。
public final class PluginManager: @unchecked Sendable {
    private let lock = NSLock()
    private let pluginsDirectory: URL
    private var plugins: [String: PluginMeta] = [:]
    private var enabled = true

    public init(pluginsDirectory: URL) {
        self.pluginsDirectory = pluginsDirectory
        reload()
    }

    public func reload() {
        let found = Self.scan(directory: pluginsDirectory)
        lock.withLock {
            plugins = found
        }
    }

    /// 扫描目录及子目录(跳过 mcp/ 与 skills/ 目录,对齐原版)
    static func scan(directory: URL) -> [String: PluginMeta] {
        // 统一解析符号链接(/var -> /private/var 等),否则 enumerator 返回的
        // 路径与传入目录路径前缀不一致,相对路径计算会出错。
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var result: [String: PluginMeta] = [:]
        for case let url as URL in enumerator {
            let resolved = url.resolvingSymlinksInPath()
            let relativeComponents = Array(resolved.pathComponents.dropFirst(root.pathComponents.count))
            // 跳过 mcp/ 与 skills/ 目录(它们由各自管理器负责)
            if relativeComponents.contains("mcp") || relativeComponents.contains("skills") {
                continue
            }
            guard url.lastPathComponent == "plugin.json",
                  let data = try? Data(contentsOf: url)
            else { continue }

            struct RawManifest: Decodable {
                let name: String?
                let version: String?
                let description: String?
                let author: String?
                let dependencies: [String]?
                let hooks: [String]?
                let policy: PluginPolicy?
            }
            guard let manifest = try? JSONDecoder().decode(RawManifest.self, from: data) else { continue }

            let id = manifest.name ?? resolved.deletingLastPathComponent().lastPathComponent
            let projectPath = relativeComponents.dropLast().joined(separator: "/")
            result[id] = PluginMeta(
                id: id,
                name: id,
                version: manifest.version ?? "0.1.0",
                description: manifest.description ?? "",
                author: manifest.author ?? "",
                dependencies: manifest.dependencies ?? [],
                projectPath: projectPath,
                hooks: manifest.hooks ?? [],
                policy: manifest.policy ?? PluginPolicy()
            )
        }
        return result
    }

    public func listPlugins() -> [PluginMeta] {
        lock.withLock {
            Array(plugins.values).sorted { $0.id < $1.id }
        }
    }

    public func plugin(id: String) -> PluginMeta? {
        lock.withLock { plugins[id] }
    }

    public func updatePolicy(id: String, policy: PluginPolicy) throws {
        try lock.withLock {
            guard var meta = plugins[id] else {
                throw PluginError.notFound(id)
            }
            meta.policy = policy
            plugins[id] = meta
        }
    }

    public func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
        }
    }

    public func isEnabled() -> Bool {
        lock.withLock { enabled }
    }

    /// 框架状态(对齐原版 get_framework_status)
    public func frameworkStatus() -> [String: Any] {
        let plugins = listPlugins()
        return [
            "enabled": isEnabled(),
            "loaded_plugins": plugins.map(\.id),
            "plugins": plugins,
            "degraded": false,
        ]
    }
}
