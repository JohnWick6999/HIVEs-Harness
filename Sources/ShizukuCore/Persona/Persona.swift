import Foundation

/// 人格模型,字段对齐原版 persona.json(兼容原格式,未知字段忽略)。
public struct Persona: Codable, Sendable, Equatable, Identifiable {
    /// 人格 id = 文件名(无扩展名),对齐原版 persona_id 语义;
    /// JSON 文件内无此字段,由 PersonaStore 在加载时注入。
    public var id: String = ""

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

        public init(name: String = "", description: String = "", version: String = "1.0", author: String = "") {
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
        systemPromptTemplate: String = ""
    ) {
        self.meta = meta
        self.character = character
        self.behaviorRules = behaviorRules
        self.replyStyle = replyStyle
        self.planStyle = planStyle
        self.systemPromptTemplate = systemPromptTemplate
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

        // system_prompt 可能是字符串模板,也可能是 {template: ...} 对象(原版格式)
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

    /// 渲染系统提示词(填充模板占位符,对齐原版 build_system_prompt)。
    public func buildSystemPrompt() -> String {
        let name = character.name.split(separator: ",").first.map(String.init) ?? meta.name
        var prompt = systemPromptTemplate
        prompt = prompt.replacingOccurrences(of: "{name}", with: name)
        prompt = prompt.replacingOccurrences(of: "{personality}", with: character.personality)
        prompt = prompt.replacingOccurrences(of: "{brother_qqid}", with: character.brotherQQID)
        prompt = prompt.replacingOccurrences(of: "{catchphrases}", with: character.catchphrases)
        return prompt
    }
}

/// 人格仓库:从 Bundle 资源或自定义目录加载 persona.json。
public struct PersonaStore: Sendable {
    private let directory: URL?

    /// - Parameter directory: 自定义人格目录(用户可扩展);nil 时使用内置资源。
    public init(directory: URL? = nil) {
        self.directory = directory
    }

    private var personaFiles: [URL] {
        // 自定义目录:直接枚举 *.json
        if let directory {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return files
                .filter { $0.hasSuffix(".json") }
                .sorted()
                .map { directory.appendingPathComponent($0) }
        }
        // Bundle 资源:.process 会压平目录结构,json 文件直接位于资源根
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func listPersonas() -> [Persona] {
        personaFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard var persona = try? JSONDecoder().decode(Persona.self, from: data) else { return nil }
            // id = 文件名(无扩展名),对齐原版 persona_id 语义
            persona.id = url.deletingPathExtension().lastPathComponent
            return persona
        }
    }

    public func load(id: String) -> Persona? {
        listPersonas().first { $0.id == id || $0.meta.name == id }
    }

    public func defaultPersona() -> Persona? {
        listPersonas().first
    }
}
