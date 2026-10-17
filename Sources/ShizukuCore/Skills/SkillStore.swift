import Foundation

/// 技能:一段可复用的任务流程指令(可选本地 handler,当前版本只注入指令)。
public struct Skill: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var version: String
    public var author: String
    public var tags: [String]
    public var body: String
    /// 用户技能目录;内置技能为 nil
    public var directory: URL?
    public var isBuiltin: Bool
    public var enabled: Bool
    public var hasHandler: Bool
    /// 使用次数与最近使用时间(来自 `.usage.json`)
    public var useCount: Int
    public var lastUsedAt: Date?

    public var isStale: Bool {
        guard let lastUsedAt else { return false }
        return Date().timeIntervalSince(lastUsedAt) > 14 * 24 * 60 * 60
    }

    public init(
        id: String,
        name: String,
        description: String,
        version: String = "0.1.0",
        author: String = "",
        tags: [String] = [],
        body: String,
        directory: URL? = nil,
        isBuiltin: Bool = false,
        enabled: Bool = true,
        hasHandler: Bool = false,
        useCount: Int = 0,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.tags = tags
        self.body = body
        self.directory = directory
        self.isBuiltin = isBuiltin
        self.enabled = enabled
        self.hasHandler = hasHandler
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }

    public var catalogLine: String {
        "- \(id): \(name) — \(description)"
    }

    public var instructions: String {
        """
        [技能: \(name)]
        \(body)

        请按以上流程继续完成任务;缺少必要信息时先向用户确认。
        """
    }
}

public enum SkillError: Error, Sendable, Equatable {
    case invalidPackage(String)
    case notInstalled(String)
}

extension SkillError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPackage(let message): return "技能包无效: \(message)"
        case .notInstalled(let id): return "技能未安装: \(id)"
        }
    }
}

/// 技能仓库:内置技能来自 Bundle,用户技能来自 `SKILL.md` 目录。
/// 用户技能按 id 覆盖内置技能;停用状态持久化到 `.disabled.json`。
public final class SkillStore: @unchecked Sendable {
    public let userDirectory: URL

    private let lock = NSLock()
    private let builtin: [Skill]
    private var cached: [Skill] = []
    private var disabled: Set<String> = []
    private var usage: [String: UsageRecord] = [:] 

    public init(userDirectory: URL) {
        self.userDirectory = userDirectory.standardizedFileURL
        self.builtin = Self.loadBuiltin()
        try? FileManager.default.createDirectory(
            at: userDirectory,
            withIntermediateDirectories: true
        )
        self.disabled = Self.loadDisabled(userDirectory)
        self.usage = Self.loadUsage(userDirectory)
        reload()
    }

    // MARK: - 查询

    public func all() -> [Skill] {
        lock.withLock { cached }
    }

    public func list() -> [Skill] {
        all().filter(\.enabled)
    }

    public func load(id: String) -> Skill? {
        all().first { $0.id == id && $0.enabled }
    }

    // MARK: - 刷新与启停

    public func reload() {
        var merged: [String: Skill] = [:]
        for skill in builtin { merged[skill.id] = skill }
        for skill in Self.scan(userDirectory) { merged[skill.id] = skill }

        let disabled = Self.loadDisabled(userDirectory)
        let usage = Self.loadUsage(userDirectory)
        let result = merged.values.map { skill -> Skill in
            var copy = skill
            copy.enabled = skill.enabled && !disabled.contains(skill.id)
            copy.useCount = usage[skill.id]?.count ?? 0
            copy.lastUsedAt = usage[skill.id]?.lastUsed
            return copy
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        lock.withLock {
            cached = result
            self.disabled = disabled
            self.usage = usage
        }
    }

    /// 记录一次技能使用(供 run_skill 与 UI 统计)。
    public func recordUse(id: String) {
        let snapshot: [String: UsageRecord] = lock.withLock {
            var next = usage
            var record = next[id] ?? UsageRecord(count: 0, lastUsed: Date())
            record.count += 1
            record.lastUsed = Date()
            next[id] = record
            usage = next
            return next
        }
        Self.saveUsage(snapshot, directory: userDirectory)
        reload()
    }

    public func usageCount(id: String) -> Int {
        lock.withLock { usage[id]?.count ?? 0 }
    }

    public func setEnabled(_ enabled: Bool, id: String) {
        var next = lock.withLock { disabled }
        if enabled { next.remove(id) } else { next.insert(id) }
        Self.saveDisabled(next, directory: userDirectory)
        reload()
    }

    // MARK: - 安装 / 卸载

    /// 从本地目录安装(目录内必须含 SKILL.md);插件市场下载后会调用这里。
    @discardableResult
    public func install(from source: URL) throws -> Skill {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SkillError.invalidPackage("技能源必须是目录")
        }
        let manifest = source.appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: manifest.path),
              let text = try? String(contentsOf: manifest, encoding: .utf8)
        else {
            throw SkillError.invalidPackage("缺少 SKILL.md")
        }
        let meta = Self.parseFrontmatter(text).meta
        let declared = Self.string(meta["id"])
        let id = declared.isEmpty ? source.lastPathComponent : declared
        let target = userDirectory.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.copyItem(at: source, to: target)
        reload()
        guard let skill = all().first(where: { $0.id == id }) else {
            throw SkillError.invalidPackage("安装后无法解析技能 \(id)")
        }
        return skill
    }

    public func remove(id: String) throws {
        let target = userDirectory.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw SkillError.notInstalled(id)
        }
        try FileManager.default.removeItem(at: target)
        reload()
    }

    // MARK: - 扫描与解析

    static func scan(_ directory: URL) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [Skill] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let text = try? String(
                      contentsOf: entry.appendingPathComponent("SKILL.md"),
                      encoding: .utf8
                  )
            else { continue }

            let parsed = parseFrontmatter(text)
            let id = string(parsed.meta["id"]).isEmpty
                ? entry.lastPathComponent
                : string(parsed.meta["id"])
            let name = string(parsed.meta["name"]).isEmpty ? id : string(parsed.meta["name"])
            let enabled = (parsed.meta["enabled"] as? Bool) ?? true
            let hasHandler = ["handler.sh", "handler.py"].contains {
                fm.fileExists(atPath: entry.appendingPathComponent($0).path)
            }
            result.append(
                Skill(
                    id: id,
                    name: name,
                    description: string(parsed.meta["description"]),
                    version: string(parsed.meta["version"]).isEmpty ? "0.1.0" : string(parsed.meta["version"]),
                    author: string(parsed.meta["author"]),
                    tags: (parsed.meta["tags"] as? [String]) ?? [],
                    body: parsed.body,
                    directory: entry,
                    isBuiltin: false,
                    enabled: enabled,
                    hasHandler: hasHandler
                )
            )
        }
        return result
    }

    /// 极简 frontmatter 解析:key: value、`- item` 列表、`[a, b]` 内联列表、true/false。
    static func parseFrontmatter(_ text: String) -> (meta: [String: Any], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else {
            return ([:], normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let lines = normalized.components(separatedBy: "\n")
        var meta: [String: Any] = [:]
        var closingIndex: Int?
        var currentKey: String?

        for index in 1..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                closingIndex = index
                break
            }
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- "), let key = currentKey {
                var items = meta[key] as? [String] ?? []
                items.append(
                    trimmed.dropFirst(2)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                )
                meta[key] = items
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                currentKey = key
                meta[key] = [String]()
                continue
            }
            currentKey = nil
            let lowered = value.lowercased()
            if lowered == "true" {
                meta[key] = true
            } else if lowered == "false" {
                meta[key] = false
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                meta[key] = value.dropFirst().dropLast()
                    .split(separator: ",")
                    .map {
                        $0.trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
            } else {
                meta[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        let bodyStart = (closingIndex ?? lines.count) + 1
        let body = lines.dropFirst(bodyStart)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (meta, body)
    }

    // MARK: - 内置技能

    private struct BuiltinSkill: Codable {
        let id: String
        let name: String
        let description: String
        let version: String
        let author: String
        let tags: [String]
        let body: String
    }

    private static func loadBuiltin() -> [Skill] {
        guard let url = Bundle.module.url(forResource: "Skills", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let definitions = try? JSONDecoder().decode([BuiltinSkill].self, from: data)
        else { return [] }
        return definitions.map {
            Skill(
                id: $0.id,
                name: $0.name,
                description: $0.description,
                version: $0.version,
                author: $0.author,
                tags: $0.tags,
                body: $0.body,
                directory: nil,
                isBuiltin: true,
                enabled: true,
                hasHandler: false
            )
        }
    }

    // MARK: - 使用遥测

    private struct UsageRecord: Codable {
        var count: Int
        var lastUsed: Date
    }

    private static func usageURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(".usage.json")
    }

    private static func loadUsage(_ directory: URL) -> [String: UsageRecord] {
        guard let data = try? Data(contentsOf: usageURL(directory)),
              let records = try? JSONDecoder().decode([String: UsageRecord].self, from: data)
        else { return [:] }
        return records
    }

    private static func saveUsage(_ usage: [String: UsageRecord], directory: URL) {
        guard let data = try? JSONEncoder().encode(usage) else { return }
        try? data.write(to: usageURL(directory), options: .atomic)
    }

    // MARK: - 停用状态

    private static func disabledURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(".disabled.json")
    }

    private static func loadDisabled(_ directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: disabledURL(directory)),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    private static func saveDisabled(_ ids: Set<String>, directory: URL) {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        try? data.write(to: disabledURL(directory), options: .atomic)
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
