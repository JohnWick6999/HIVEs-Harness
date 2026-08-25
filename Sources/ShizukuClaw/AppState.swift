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

    /// 流式发送:文本增量实时更新最后一条助手消息(打字机效果)
    func sendStreaming(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        messages.append(.text(.user, trimmed))
        isBusy = true
        errorMessage = nil
        lastToolTrace = []
        defer { isBusy = false }

        // 占位助手消息,流式期间原地更新
        let placeholderID = UUID()
        messages.append(ChatMessage(role: .assistant, content: .text(""), id: placeholderID))

        let loop = AgentLoop(
            store: store,
            config: config,
            keychain: keychain,
            personas: personas,
            workspace: workspace
        )
        do {
            for try await event in await loop.stream(message: trimmed, persona: selectedPersona) {
                switch event {
                case .chunk(let delta):
                    if let last = messages.last(where: { $0.id == placeholderID }),
                       case .text(let current) = last.content {
                        updateAssistantMessage(id: placeholderID, text: current + delta)
                    }
                case .toolCalled(let trace):
                    lastToolTrace.append(trace)
                case .fallback(let text):
                    updateAssistantMessage(id: placeholderID, text: text)
                case .limitReached(let text):
                    updateAssistantMessage(id: placeholderID, text: text)
                case .finished(let result):
                    updateAssistantMessage(id: placeholderID, text: result.reply)
                    lastToolTrace = result.trace
                }
            }
        } catch {
            updateAssistantMessage(id: placeholderID, text: "⚠️ 调用失败: \(error.localizedDescription)")
        }
    }

    private func updateAssistantMessage(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = ChatMessage(role: .assistant, content: .text(text), id: id)
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
