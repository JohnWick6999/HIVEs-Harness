import Foundation

/// 应用配置,字段对齐原版 `config/settings.yaml`。
/// 敏感字段(API Key)不在此结构内,统一走 `KeychainStore`。
public struct AppConfig: Codable, Sendable, Equatable {
    public struct LLM: Codable, Sendable, Equatable {
        /// 供应商标识:openai_compatible / ollama / openai
        public var provider: String
        /// 模型名,如 gpt-4o-mini / qwen2.5 / deepseek-chat
        public var model: String
        /// OpenAI 兼容端点,如 https://api.openai.com/v1 或本地中转
        public var baseURL: String
        /// 采样温度
        public var temperature: Double
        /// 模型上下文窗口(token);未知时按 32768 估算
        public var contextWindow: Int
        /// 预留的最大输出 token
        public var maxOutputTokens: Int

        public init(
            provider: String = "openai_compatible",
            model: String = "gpt-4o-mini",
            baseURL: String = "https://api.openai.com/v1",
            temperature: Double = 0.4,
            contextWindow: Int = 32_768,
            maxOutputTokens: Int = 4_096
        ) {
            self.provider = provider
            self.model = model
            self.baseURL = baseURL
            self.temperature = temperature
            self.contextWindow = contextWindow
            self.maxOutputTokens = maxOutputTokens
        }

        private enum CodingKeys: String, CodingKey {
            case provider, model, baseURL, temperature, contextWindow, maxOutputTokens
        }

        /// 兼容旧配置文件:新增字段缺失时使用默认值,避免整份配置解码失败。
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "openai_compatible"
            model = try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-4o-mini"
            baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
            temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.4
            contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 32_768
            maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 4_096
        }
    }

    public struct Agent: Codable, Sendable, Equatable {
        /// 工具调用最大轮数(原版 MAX_TOOL_ROUNDS = 6)
        public var maxRounds: Int
        /// 系统提示词模板
        public var systemPrompt: String
        /// 默认人格 id
        public var defaultPersona: String
        /// 工作模式(chat / sandbox / full)
        public var workMode: WorkMode

        public init(
            maxRounds: Int = 6,
            systemPrompt: String = "你是一个智能助手,请根据用户意图选择工具或直接回答。",
            defaultPersona: String = "shizuku",
            workMode: WorkMode = .sandbox
        ) {
            self.maxRounds = maxRounds
            self.systemPrompt = systemPrompt
            self.defaultPersona = defaultPersona
            self.workMode = workMode
        }

        private enum CodingKeys: String, CodingKey {
            case maxRounds, systemPrompt, defaultPersona, workMode
        }

        /// 兼容旧配置文件:workMode 缺失时按安全模式处理。
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            maxRounds = try container.decodeIfPresent(Int.self, forKey: .maxRounds) ?? 6
            systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
                ?? "你是一个智能助手,请根据用户意图选择工具或直接回答。"
            defaultPersona = try container.decodeIfPresent(String.self, forKey: .defaultPersona) ?? "shizuku"
            workMode = try container.decodeIfPresent(WorkMode.self, forKey: .workMode) ?? .sandbox
        }
    }

    public var llm: LLM
    public var agent: Agent
    /// 多提供商 / 多模型 / 回退组(旧配置为空时由 normalized() 自动迁移)
    public var providers: [String: ProviderConfig]
    public var models: [String: ModelConfig]
    public var modelGroups: [String: ModelGroup]
    public var defaultModelGroup: String

    public static let `default` = AppConfig()

    public init(
        llm: LLM = .init(),
        agent: Agent = .init(),
        providers: [String: ProviderConfig] = [:],
        models: [String: ModelConfig] = [:],
        modelGroups: [String: ModelGroup] = [:],
        defaultModelGroup: String = "default"
    ) {
        self.llm = llm
        self.agent = agent
        self.providers = providers
        self.models = models
        self.modelGroups = modelGroups
        self.defaultModelGroup = defaultModelGroup
    }

    private enum CodingKeys: String, CodingKey {
        case llm, agent, providers, models, modelGroups, defaultModelGroup
    }

    /// 兼容旧配置:新增字段缺失时使用默认值,避免整份配置解码失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        llm = try container.decodeIfPresent(LLM.self, forKey: .llm) ?? LLM()
        agent = try container.decodeIfPresent(Agent.self, forKey: .agent) ?? Agent()
        providers = try container.decodeIfPresent([String: ProviderConfig].self, forKey: .providers) ?? [:]
        models = try container.decodeIfPresent([String: ModelConfig].self, forKey: .models) ?? [:]
        modelGroups = try container.decodeIfPresent([String: ModelGroup].self, forKey: .modelGroups) ?? [:]
        defaultModelGroup = try container.decodeIfPresent(String.self, forKey: .defaultModelGroup) ?? "default"
    }

    /// 把旧版单模型配置迁移成 provider/model/group,并补齐缺失的默认值。
    public func normalized() -> AppConfig {
        var copy = self
        if copy.providers.isEmpty {
            copy.providers = [
                "default": ProviderConfig(
                    id: "default",
                    name: "默认提供商",
                    type: copy.llm.provider,
                    baseURL: copy.llm.baseURL,
                    enabled: true
                )
            ]
        }
        if copy.models.isEmpty {
            let providerID = copy.providers.keys.sorted().first ?? "default"
            copy.models = [
                "primary": ModelConfig(
                    id: "primary",
                    provider: providerID,
                    model: copy.llm.model,
                    name: copy.llm.model,
                    capabilities: ["chat", "tools"],
                    enabled: true,
                    contextWindow: copy.llm.contextWindow,
                    maxOutputTokens: copy.llm.maxOutputTokens,
                    temperature: copy.llm.temperature
                )
            ]
        }
        if copy.modelGroups.isEmpty {
            let modelID = copy.models.keys.sorted().first ?? "primary"
            copy.modelGroups = [
                "default": ModelGroup(
                    id: "default",
                    name: "默认模型组",
                    purpose: "agent",
                    models: [modelID]
                )
            ]
        }
        if copy.modelGroups[copy.defaultModelGroup] == nil {
            copy.defaultModelGroup = copy.modelGroups.keys.sorted().first ?? "default"
        }
        if let group = copy.modelGroups[copy.defaultModelGroup], group.models.isEmpty {
            let modelID = copy.models.keys.sorted().first ?? "primary"
            copy.modelGroups[copy.defaultModelGroup]?.models = [modelID]
        }
        return copy
    }
}

/// 配置文件读写(JSON,原生 Codable,不引第三方 YAML 依赖)。
public struct ConfigStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 读取配置;文件不存在或损坏时回退默认值(与原版静默回退行为一致)。
    /// 旧配置的 provider/model 迁移由调用方 `normalized()` 或 ModelRegistry 完成。
    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    public func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}
