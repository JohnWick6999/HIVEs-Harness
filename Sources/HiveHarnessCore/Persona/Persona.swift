import Foundation

/// 人格模型,字段对齐原版 persona.json(兼容原格式,未知字段忽略)。
public struct Persona: Codable, Sendable, Equatable, Identifiable {
    /// 人格 id = 文件名(无扩展名)。
    public var id: String = ""
    /// 是否内置人格(运行时标记,不写入用户文件)。
    public var isBuiltin: Bool = false

    public struct Character: Codable, Sendable, Equatable {
        public var name: String
        public var personality: String
        public var brotherQQID: String
        public var catchphrases: String

        public init(
            name: String = "",
            personality: String = "",
            brotherQQID: String = "",
            catchphrases: String = ""
        ) {
            self.name = name
            self.personality = personality
            self.brotherQQID = brotherQQID
            self.catchphrases = catchphrases
        }

        enum CodingKeys: String, CodingKey {
            case name, personality
            case brotherQQID = "brother_qqid"
            case catchphrases
        }
    }

    public struct Meta: Codable, Sendable, Equatable {
        public var name: String
        public var description: String
        public var version: String
        public var author: String

        public init(name: String = "", description: String = "", version: String = "1.0", author: String = "HIVE") {
            self.name = name
            self.description = description
            self.version = version
            self.author = author
        }
    }

    public var meta: Meta
    public var character: Character
    public var behaviorRules: [String]
    public var replyStyle: String
    public var planStyle: String
    public var systemPromptTemplate: String

    public init(
        meta: Meta,
        character: Character,
        behaviorRules: [String] = [],
        replyStyle: String = "",
        planStyle: String = "",
        systemPromptTemplate: String = "",
        isBuiltin: Bool = false
    ) {
        self.meta = meta
        self.character = character
        self.behaviorRules = behaviorRules
        self.replyStyle = replyStyle
        self.planStyle = planStyle
        self.systemPromptTemplate = systemPromptTemplate
        self.isBuiltin = isBuiltin
    }

    enum CodingKeys: String, CodingKey {
        case id, meta, character
        case behaviorRules = "behavior_rules"
        case replyStyle = "reply_style"
        case planStyle = "plan_style"
        case systemPromptTemplate = "system_prompt"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        meta = (try? container.decode(Meta.self, forKey: .meta)) ?? Meta()
        character = (try? container.decode(Character.self, forKey: .character)) ?? Character()
        behaviorRules = (try? container.decode([String].self, forKey: .behaviorRules)) ?? []
        replyStyle = (try? container.decode(String.self, forKey: .replyStyle)) ?? ""
        planStyle = (try? container.decode(String.self, forKey: .planStyle)) ?? ""
        isBuiltin = false

        if let template = try? container.decode(String.self, forKey: .systemPromptTemplate) {
            systemPromptTemplate = template
        } else if let dict = try? container.decode([String: String].self, forKey: .systemPromptTemplate) {
            systemPromptTemplate = dict["template"] ?? ""
        } else {
            systemPromptTemplate = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(meta, forKey: .meta)
        try container.encode(character, forKey: .character)
        try container.encode(behaviorRules, forKey: .behaviorRules)
        try container.encode(replyStyle, forKey: .replyStyle)
        try container.encode(planStyle, forKey: .planStyle)
        try container.encode(systemPromptTemplate, forKey: .systemPromptTemplate)
    }

    /// 渲染系统提示词(填充模板占位符,并追加规则/风格)。
    public func buildSystemPrompt() -> String {
        let name = character.name.split(separator: ",").first.map(String.init) ?? meta.name
        var prompt = systemPromptTemplate
        prompt = prompt.replacingOccurrences(of: "{name}", with: name)
        prompt = prompt.replacingOccurrences(of: "{personality}", with: character.personality)
        prompt = prompt.replacingOccurrences(of: "{brother_qqid}", with: character.brotherQQID)
        prompt = prompt.replacingOccurrences(of: "{catchphrases}", with: character.catchphrases)

        var sections: [String] = []
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(prompt)
        }
        if !behaviorRules.isEmpty {
            sections.append(
                "[行为规则]\n" + behaviorRules.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if !replyStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("[回复风格]\n\(replyStyle)")
        }
        if !planStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("[行为规划]\n\(planStyle)")
        }
        return sections.joined(separator: "\n\n")
    }
}

public enum PersonaError: Error, Sendable, Equatable {
    case builtinCannotBeDeleted(String)
    case notFound(String)
    case readOnly
}

extension PersonaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .builtinCannotBeDeleted(let id): return "内置人格不可删除;可恢复默认: \(id)"
        case .notFound(let id): return "人格不存在: \(id)"
        case .readOnly: return "当前人格目录不可写"
        }
    }
}

/// 人格仓库:内置人格来自 Bundle;用户自定义/覆盖存于用户目录。
/// 内置人格永不被删除,可被用户覆盖并恢复默认;自定义人格可增删。
public struct PersonaStore: Sendable {
    private let userDirectory: URL?

    /// 仅内置人格(测试/只读场景)。
    public init() {
        self.userDirectory = nil
    }

    /// 内置 + 指定用户目录。
    public init(directory: URL?) {
        self.userDirectory = directory
    }

    /// 内置 + 用户人格目录(应用使用)。
    public init(userDirectory: URL) {
        self.userDirectory = userDirectory
    }

    // MARK: - 查询

    public func listPersonas() -> [Persona] {
        let builtins = builtinPersonas()
        let builtinIDs = Set(builtins.map(\.id))
        var merged: [String: Persona] = [:]
        var order: [String] = []
        for persona in builtins {
            merged[persona.id] = persona
            order.append(persona.id)
        }
        for var persona in userPersonas() {
            persona.isBuiltin = builtinIDs.contains(persona.id)
            if merged[persona.id] == nil {
                order.append(persona.id)
            }
            merged[persona.id] = persona
        }
        return order.compactMap { merged[$0] }
    }

    public func load(id: String) -> Persona? {
        listPersonas().first { $0.id == id }
    }

    public func defaultPersona() -> Persona? {
        load(id: "assistant") ?? listPersonas().first
    }

    public func isBuiltin(id: String) -> Bool {
        builtinPersonas().contains { $0.id == id }
    }

    /// 内置人格是否已被用户覆盖。
    public func isCustomized(id: String) -> Bool {
        guard isBuiltin(id: id), let userDirectory else { return false }
        return FileManager.default.fileExists(
            atPath: userDirectory.appendingPathComponent("\(id).json").path
        )
    }

    // MARK: - 写入

    public func save(_ persona: Persona) throws {
        guard let userDirectory else { throw PersonaError.readOnly }
        var copy = persona
        if copy.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.id = Self.makeCustomID()
        }
        copy.id = Self.sanitizeID(copy.id)
        if copy.meta.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.meta.name = copy.character.name.isEmpty ? copy.id : copy.character.name
        }
        if copy.character.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.character.name = copy.meta.name
        }
        try FileManager.default.createDirectory(
            at: userDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(copy)
        try data.write(
            to: userDirectory.appendingPathComponent("\(copy.id).json"),
            options: .atomic
        )
    }

    public func delete(id: String) throws {
        guard isBuiltin(id: id) == false else {
            throw PersonaError.builtinCannotBeDeleted(id)
        }
        guard let userDirectory else { throw PersonaError.readOnly }
        let url = userDirectory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PersonaError.notFound(id)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// 删除用户对内置人格的覆盖,恢复出厂内容。
    public func resetBuiltin(id: String) throws {
        guard isBuiltin(id: id) else { throw PersonaError.notFound(id) }
        guard let userDirectory else { throw PersonaError.readOnly }
        let url = userDirectory.appendingPathComponent("\(id).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 内置/用户加载

    private func builtinPersonas() -> [Persona] {
        let preferred = ["assistant", "engineer", "researcher", "writer", "analyst", "planner", "tutor"]
        let urls = (Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .sorted { lhs, rhs in
                let left = lhs.deletingPathExtension().lastPathComponent
                let right = rhs.deletingPathExtension().lastPathComponent
                let leftIndex = preferred.firstIndex(of: left) ?? Int.max
                let rightIndex = preferred.firstIndex(of: right) ?? Int.max
                if leftIndex != rightIndex { return leftIndex < rightIndex }
                return left < right
            }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  var persona = try? JSONDecoder().decode(Persona.self, from: data)
            else { return nil }
            persona.id = url.deletingPathExtension().lastPathComponent
            persona.isBuiltin = true
            return persona
        }
    }

    private func userPersonas() -> [Persona] {
        guard let userDirectory else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: userDirectory.path)) ?? []
        return files
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
            .compactMap { filename in
                let url = userDirectory.appendingPathComponent(filename)
                guard let data = try? Data(contentsOf: url),
                      var persona = try? JSONDecoder().decode(Persona.self, from: data)
                else { return nil }
                persona.id = (filename as NSString).deletingPathExtension
                persona.isBuiltin = false
                return persona
            }
    }

    // MARK: - ID

    public static func makeCustomID() -> String {
        "custom-" + UUID().uuidString.lowercased().prefix(8)
    }

    static func sanitizeID(_ raw: String) -> String {
        var result = ""
        for character in raw.lowercased() {
            if (character.isASCII && character.isLetter)
                || (character.isASCII && character.isNumber)
                || character == "-" || character == "_" {
                result.append(character)
            } else {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return result.isEmpty ? makeCustomID() : String(result.prefix(60))
    }
}
