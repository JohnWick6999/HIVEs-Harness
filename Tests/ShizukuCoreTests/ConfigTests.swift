import Foundation
@testable import ShizukuCore
import Testing

@Suite("AppConfig")
struct AppConfigTests {
    @Test("默认值与原版对齐")
    func defaults() {
        let config = AppConfig.default
        #expect(config.llm.provider == "openai_compatible")
        #expect(config.llm.model == "gpt-4o-mini")
        #expect(config.llm.temperature == 0.4)
        #expect(config.agent.maxRounds == 6)
        #expect(config.agent.defaultPersona == "shizuku")
    }

    @Test("JSON 编解码往返")
    func roundtrip() throws {
        var config = AppConfig.default
        config.llm.model = "deepseek-chat"
        config.llm.baseURL = "https://api.example.com/v1"
        config.agent.maxRounds = 10

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test("ConfigStore:文件不存在时回退默认值")
    func missingFileFallback() {
        let store = ConfigStore(fileURL: URL(fileURLWithPath: "/nonexistent/path/config.json"))
        #expect(store.load() == .default)
    }

    @Test("ConfigStore:保存后可读回")
    func saveLoadRoundtrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shizuku-test-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var config = AppConfig.default
        config.agent.defaultPersona = "azuma"
        let store = ConfigStore(fileURL: url)
        try store.save(config)
        #expect(store.load() == config)
    }
}

@Suite("KeychainStore")
struct KeychainStoreTests {
    @Test("set/get/delete 往返")
    func roundtrip() throws {
        let keychain = KeychainStore(service: "com.shizukuclaw.test.\(UUID().uuidString)")
        let key = "api_key"
        defer { try? keychain.delete(forKey: key) }

        // 初始不存在
        #expect(try keychain.string(forKey: key) == nil)

        try keychain.setString("sk-test-123", forKey: key)
        #expect(try keychain.string(forKey: key) == "sk-test-123")

        try keychain.delete(forKey: key)
        #expect(try keychain.string(forKey: key) == nil)
    }

    @Test("更新已有值")
    func update() throws {
        let keychain = KeychainStore(service: "com.shizukuclaw.test.\(UUID().uuidString)")
        let key = "api_key"
        defer { try? keychain.delete(forKey: key) }

        try keychain.setString("v1", forKey: key)
        try keychain.setString("v2", forKey: key)
        #expect(try keychain.string(forKey: key) == "v2")
    }
}
