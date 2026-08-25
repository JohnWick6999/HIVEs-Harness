import Foundation
import Observation
import ShizukuCore

/// 全局应用状态:配置、会话、与核心库的桥接。
@MainActor
@Observable
final class AppState {
    // MARK: - 对外状态

    var messages: [ChatMessage] = []
    var isBusy = false
    var selectedPersona: String
    var config: AppConfig
    var apiKey: String
    var errorMessage: String?
    var lastToolTrace: [ToolTrace] = []

    // MARK: - 依赖

    let store: SQLiteStore
    let workspace: URL
    private let configStore: ConfigStore
    private let keychain: KeychainStore
    private let personas: PersonaStore

    init() {
        // 数据目录:~/Library/Application Support/ShizukuClaw/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("ShizukuClaw", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        configStore = ConfigStore(fileURL: base.appendingPathComponent("config.json"))
        keychain = KeychainStore(service: "com.shizukuclaw.app")
        personas = PersonaStore()
        workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let loadedConfig = configStore.load()
        config = loadedConfig
        apiKey = (try? keychain.string(forKey: "llm.api_key")) ?? ""
        selectedPersona = loadedConfig.agent.defaultPersona
        store = try! SQLiteStore(path: base.appendingPathComponent("agent.db").path)

        loadHistory()
    }

    var threadID: String { "persona:\(selectedPersona)" }

    /// 从存储恢复当前人格的对话历史
    func loadHistory() {
        messages = (try? store.loadMessages(threadID: threadID, persona: selectedPersona)) ?? []
    }

    func selectPersona(_ id: String) {
        selectedPersona = id
        loadHistory()
    }

    /// 发送消息并调用 Agent(无 API Key 时核心自动走本地回退)
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        messages.append(.text(.user, trimmed))
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        let loop = AgentLoop(
            store: store,
            config: config,
            keychain: keychain,
            personas: personas,
            workspace: workspace
        )
        do {
            let result = try await loop.invoke(message: trimmed, persona: selectedPersona)
            messages.append(.text(.assistant, result.reply))
            lastToolTrace = result.trace
        } catch {
            errorMessage = "调用失败: \(error.localizedDescription)"
        }
    }

    /// 持久化配置与 API Key
    func saveConfig() {
        try? configStore.save(config)
        try? keychain.setString(apiKey, forKey: "llm.api_key")
    }

    var availablePersonas: [Persona] {
        personas.listPersonas()
    }
}
