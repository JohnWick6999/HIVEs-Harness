import Foundation
@testable import ShizukuCore
import Testing

private struct FailingLLMClient: LLMClient {
    func chat(messages: [ChatMessage], tools: [ToolSpec]?) async throws -> LLMResponse {
        throw LLMError.transport("模拟首个模型不可用")
    }

    func stream(messages: [ChatMessage], tools: [ToolSpec]?) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMError.transport("模拟首个模型不可用"))
        }
    }

    func embed(text: String) async throws -> [Double]? { nil }
}

private func multiModelConfig() -> AppConfig {
    var config = AppConfig.default
    config.providers = [
        "p1": ProviderConfig(id: "p1", name: "P1", baseURL: "https://p1.example/v1"),
        "p2": ProviderConfig(id: "p2", name: "P2", baseURL: "https://p2.example/v1"),
    ]
    config.models = [
        "m1": ModelConfig(id: "m1", provider: "p1", model: "model-one"),
        "m2": ModelConfig(id: "m2", provider: "p2", model: "model-two"),
    ]
    config.modelGroups = [
        "default": ModelGroup(id: "default", name: "默认", purpose: "agent", models: ["m1", "m2"])
    ]
    config.defaultModelGroup = "default"
    return config
}

@Suite("模型注册表")
struct ModelRegistryTests {
    @Test("旧版单模型配置自动迁移为 provider/model/group")
    func legacyMigration() {
        let normalized = AppConfig.default.normalized()
        #expect(normalized.providers.count == 1)
        #expect(normalized.models.count == 1)
        #expect(normalized.modelGroups["default"]?.models.count == 1)
        #expect(normalized.models["primary"]?.model == normalized.llm.model)
        #expect(normalized.models["primary"]?.contextWindow == normalized.llm.contextWindow)
    }

    @Test("解析提供商与钥匙串 Key")
    func resolveProviderKey() throws {
        let keychain = KeychainStore(service: "com.shizukuclaw.registry.\(UUID().uuidString)")
        try keychain.setString("sk-p1", forKey: ModelRegistry.apiKeyKey(providerID: "p1"))
        let config = multiModelConfig()
        let registry = ModelRegistry(config: config, keychain: keychain)

        let resolved = try registry.resolve(modelID: "m1")
        #expect(resolved.apiKey == "sk-p1")
        #expect(resolved.provider.baseURL == "https://p1.example/v1")
        #expect(resolved.model.model == "model-one")
    }

    @Test("提供商未单独配置 Key 时回退旧版 llm.api_key")
    func legacyKeyFallback() throws {
        let keychain = KeychainStore(service: "com.shizukuclaw.registry.\(UUID().uuidString)")
        try keychain.setString("sk-legacy", forKey: "llm.api_key")
        var config = multiModelConfig()
        config.providers = [
            "default": ProviderConfig(id: "default", name: "默认", baseURL: "https://api.example/v1")
        ]
        config.models = [
            "m1": ModelConfig(id: "m1", provider: "default", model: "model-one")
        ]
        config.modelGroups = [
            "default": ModelGroup(id: "default", name: "默认", models: ["m1"])
        ]
        let registry = ModelRegistry(config: config, keychain: keychain)
        #expect(try registry.resolve(modelID: "m1").apiKey == "sk-legacy")
    }

    @Test("候选链过滤停用/辅助/缺少 chat 能力的模型")
    func candidatesFiltering() throws {
        var config = multiModelConfig()
        config.models["m1"]?.enabled = false
        config.models["m2"]?.capabilities = ["vision"]
        config.models["m3"] = ModelConfig(
            id: "m3",
            provider: "p1",
            model: "aux",
            capabilities: ["chat"],
            auxiliaryOnly: true
        )
        config.models["m4"] = ModelConfig(
            id: "m4",
            provider: "p2",
            model: "usable",
            capabilities: ["chat", "tools"]
        )
        config.modelGroups["default"]?.models = ["m1", "m2", "m3", "m4"]
        let registry = ModelRegistry(
            config: config,
            keychain: KeychainStore(service: "com.shizukuclaw.registry.\(UUID().uuidString)")
        )

        #expect(try registry.agentCandidates().map(\.id) == ["m4"])
    }

    @Test("模型组不存在时抛出明确错误")
    func unknownGroup() {
        let registry = ModelRegistry(
            config: multiModelConfig(),
            keychain: KeychainStore(service: "com.shizukuclaw.registry.\(UUID().uuidString)")
        )
        #expect(throws: ModelRegistryError.unknownGroup("nope")) {
            _ = try registry.agentCandidates(groupID: "nope")
        }
    }

    @Test("AgentLoop 非流式回退到下一个模型")
    func nonStreamingFallback() async throws {
        let keychain = KeychainStore(service: "com.shizukuclaw.registry.\(UUID().uuidString)")
        try keychain.setString("k1", forKey: ModelRegistry.apiKeyKey(providerID: "p1"))
        try keychain.setString("k2", forKey: ModelRegistry.apiKeyKey(providerID: "p2"))

        let ws = try tempDir()
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-fallback-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)

        let mock = MockLLMClient(responses: [LLMResponse(content: "来自备用模型")])
        let loop = AgentLoop(
            store: store,
            config: multiModelConfig(),
            keychain: keychain,
            workspace: ws,
            clientFactory: { resolved -> any LLMClient in
                resolved.id == "m1" ? FailingLLMClient() : mock
            }
        )

        let result = try await loop.invoke(message: "你好")
        #expect(result.reply == "来自备用模型")
        #expect(result.activeModel == "m2")
    }

    @Test("AgentLoop 流式首包失败时回退")
    func streamingFallback() async throws {
        let keychain = KeychainStore(service: "com.shizukuclaw.registry.\(UUID().uuidString)")
        try keychain.setString("k1", forKey: ModelRegistry.apiKeyKey(providerID: "p1"))
        try keychain.setString("k2", forKey: ModelRegistry.apiKeyKey(providerID: "p2"))

        let ws = try tempDir()
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-fallback-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)

        let mock = MockLLMClient(
            responses: [],
            streamResponses: [[LLMStreamChunk(delta: "备用"), LLMStreamChunk(delta: "模型")]]
        )
        let loop = AgentLoop(
            store: store,
            config: multiModelConfig(),
            keychain: keychain,
            workspace: ws,
            clientFactory: { resolved -> any LLMClient in
                resolved.id == "m1" ? FailingLLMClient() : mock
            }
        )

        var text = ""
        var finished: AgentResult?
        for try await event in await loop.stream(message: "你好") {
            switch event {
            case .chunk(let delta): text += delta
            case .finished(let result): finished = result
            default: break
            }
        }
        #expect(text == "备用模型")
        #expect(finished?.activeModel == "m2")
    }
}
