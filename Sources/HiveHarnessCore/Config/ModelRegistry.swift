import Foundation

/// 提供商:一组凭据 + 一个 OpenAI 兼容端点。
public struct ProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// openai_compatible | ollama
    public var type: String
    public var baseURL: String
    public var enabled: Bool

    public init(
        id: String,
        name: String,
        type: String = "openai_compatible",
        baseURL: String = "https://api.openai.com/v1",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.enabled = enabled
    }

    public var isOllama: Bool { type == "ollama" }
}

/// 模型:能力标签 + 上下文预算 + 采样参数。
public struct ModelConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var provider: String
    /// 实际发给端点的模型名
    public var model: String
    /// 展示名
    public var name: String
    /// chat / tools / vision / image / speech / search / embedding
    public var capabilities: [String]
    public var enabled: Bool
    /// 辅助模型(生图/语音/搜索/嵌入)不能进入 Agent 回退链
    public var auxiliaryOnly: Bool
    public var contextWindow: Int
    public var maxOutputTokens: Int
    public var temperature: Double

    public init(
        id: String,
        provider: String,
        model: String,
        name: String = "",
        capabilities: [String] = ["chat", "tools"],
        enabled: Bool = true,
        auxiliaryOnly: Bool = false,
        contextWindow: Int = 32_768,
        maxOutputTokens: Int = 4_096,
        temperature: Double = 0.4
    ) {
        self.id = id
        self.provider = provider
        self.model = model
        self.name = name.isEmpty ? model : name
        self.capabilities = capabilities
        self.enabled = enabled
        self.auxiliaryOnly = auxiliaryOnly
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }

    public var isAgentCapable: Bool {
        enabled && !auxiliaryOnly && capabilities.contains("chat")
    }
}

/// 模型组:Agent 按顺序尝试的候选链。
public struct ModelGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// agent(参与对话回退链)或其他用途
    public var purpose: String
    public var models: [String]

    public init(
        id: String,
        name: String,
        purpose: String = "agent",
        models: [String] = []
    ) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.models = models
    }
}

public enum ModelRegistryError: Error, Sendable, Equatable {
    case unknownGroup(String)
    case unknownModel(String)
    case unknownProvider(String)
    case disabledModel(String)
    case disabledProvider(String)
    case noUsableModels(String)
}

extension ModelRegistryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownGroup(let id): return "模型组不存在: \(id)"
        case .unknownModel(let id): return "模型不存在: \(id)"
        case .unknownProvider(let id): return "提供商不存在: \(id)"
        case .disabledModel(let id): return "模型已停用: \(id)"
        case .disabledProvider(let id): return "提供商已停用: \(id)"
        case .noUsableModels(let id): return "模型组没有可用模型: \(id)"
        }
    }
}

/// 解析后的模型:模型配置 + 提供商 + 从钥匙串取出的 API Key。
public struct ResolvedModel: Sendable, Equatable {
    public let id: String
    public let provider: ProviderConfig
    public let model: ModelConfig
    public let apiKey: String

    public init(id: String, provider: ProviderConfig, model: ModelConfig, apiKey: String) {
        self.id = id
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
    }
}

/// 模型注册表:解析提供商、模型与 Agent 回退组。
public struct ModelRegistry: Sendable {
    public let providers: [String: ProviderConfig]
    public let models: [String: ModelConfig]
    public let groups: [String: ModelGroup]
    public let defaultGroup: String
    public let keychain: any KeychainStoring

    public init(config: AppConfig, keychain: any KeychainStoring) {
        let normalized = config.normalized()
        self.providers = normalized.providers
        self.models = normalized.models
        self.groups = normalized.modelGroups
        self.defaultGroup = normalized.defaultModelGroup
        self.keychain = keychain
    }

    /// Agent 候选链(按组内顺序,过滤停用/辅助模型)。
    public func agentCandidates(groupID: String? = nil) throws -> [ResolvedModel] {
        let id = groupID ?? defaultGroup
        guard let group = groups[id] else { throw ModelRegistryError.unknownGroup(id) }
        guard group.purpose == "agent" else {
            throw ModelRegistryError.noUsableModels(id)
        }
        let resolved = group.models.compactMap { modelID -> ResolvedModel? in
            try? resolve(modelID: modelID)
        }
        let usable = resolved.filter { $0.model.isAgentCapable && $0.provider.enabled }
        guard !usable.isEmpty else { throw ModelRegistryError.noUsableModels(id) }
        return usable
    }

    public func resolve(modelID: String) throws -> ResolvedModel {
        guard let model = models[modelID] else {
            throw ModelRegistryError.unknownModel(modelID)
        }
        guard model.enabled else { throw ModelRegistryError.disabledModel(modelID) }
        guard let provider = providers[model.provider] else {
            throw ModelRegistryError.unknownProvider(model.provider)
        }
        guard provider.enabled else { throw ModelRegistryError.disabledProvider(model.provider) }

        let stored = (try? keychain.string(forKey: Self.apiKeyKey(providerID: provider.id))) ?? nil
        let legacy = (try? keychain.string(forKey: "llm.api_key")) ?? nil
        let apiKey = (stored?.isEmpty == false ? stored : legacy) ?? ""
        return ResolvedModel(id: modelID, provider: provider, model: model, apiKey: apiKey)
    }

    /// 提供商 API Key 在钥匙串中的键名。
    public static func apiKeyKey(providerID: String) -> String {
        "provider.\(providerID).api_key"
    }
}
