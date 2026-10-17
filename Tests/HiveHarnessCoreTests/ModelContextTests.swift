import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("模型上下文自动适配")
struct ModelContextTests {
    @Test("已知模型上下文表")
    func resolver() {
        #expect(ModelContextResolver.contextWindow(for: "deepseek-flash") == 100_000_000)
        #expect(ModelContextResolver.contextWindow(for: "deepseek-v4-pro") == 100_000_000)
        #expect(ModelContextResolver.contextWindow(for: "deepseek-chat") == 128_000)
        #expect(ModelContextResolver.contextWindow(for: "gpt-4o-mini") == 128_000)
        #expect(ModelContextResolver.contextWindow(for: "unknown-model") == nil)
    }

    @Test("normalized 自动更新窗口与 llm.contextWindow")
    func normalized() {
        var config = AppConfig.default
        config.providers = [
            "p": ProviderConfig(id: "p", name: "P", baseURL: "https://api.deepseek.com"),
        ]
        config.models = [
            "m": ModelConfig(
                id: "m",
                provider: "p",
                model: "deepseek-flash",
                contextWindow: 32_768
            ),
        ]
        config.modelGroups = [
            "g": ModelGroup(id: "g", name: "G", models: ["m"]),
        ]
        config.defaultModelGroup = "g"

        let normalized = config.normalized()
        #expect(normalized.models["m"]?.contextWindow == 100_000_000)
        #expect(normalized.llm.contextWindow == 100_000_000)
    }

    @Test("ModelRegistry 解析时也自动适配")
    func registryResolve() throws {
        var config = AppConfig.default
        config.providers = [
            "p": ProviderConfig(id: "p", name: "P", baseURL: "https://api.deepseek.com"),
        ]
        config.models = [
            "m": ModelConfig(id: "m", provider: "p", model: "deepseek-flash"),
        ]
        let registry = ModelRegistry(
            config: config,
            keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)")
        )
        let resolved = try registry.resolve(modelID: "m")
        #expect(resolved.model.contextWindow == 100_000_000)
    }

    @Test("旧配置缺字段时默认自动并检测")
    func legacyDecode() throws {
        let json = """
        {"id":"m","provider":"p","model":"deepseek-flash"}
        """
        let model = try JSONDecoder().decode(ModelConfig.self, from: Data(json.utf8))
        #expect(model.autoContextWindow)
        #expect(model.contextWindow == 100_000_000)
    }
}
