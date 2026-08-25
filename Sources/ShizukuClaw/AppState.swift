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
        // 工作区放在用户可见的 Documents/ShizukuClaw/(Application Support 深处用户找不到)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        workspace = documents.appendingPathComponent("ShizukuClaw", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        // 迁移旧工作区文件(Application Support/workspace -> Documents/ShizukuClaw)
        let legacyWorkspace = base.appendingPathComponent("workspace", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyWorkspace.path) {
            if let legacyFiles = try? FileManager.default.contentsOfDirectory(atPath: legacyWorkspace.path) {
                for file in legacyFiles {
                    let src = legacyWorkspace.appendingPathComponent(file)
                    let dst = workspace.appendingPathComponent(file)
                    if !FileManager.default.fileExists(atPath: dst.path) {
                        try? FileManager.default.copyItem(at: src, to: dst)
                    }
                }
            }
            try? FileManager.default.removeItem(at: legacyWorkspace)
        }

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
        typingPending = ""
        typingTask?.cancel()
        typingTask = nil
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
                    // 增量进缓冲区,由打字动画 Task 平滑渲染
                    typingPending += delta
                    pumpTyping(placeholderID: placeholderID)
                case .toolCalled(let trace):
                    lastToolTrace.append(trace)
                    // 产出文件挂到当前助手消息,渲染为可点击附件卡片
                    if !trace.files.isEmpty,
                       let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                        var message = messages[index]
                        message.fileAttachments = trace.files.map { FileAttachment(path: $0) }
                        messages[index] = message
                    }
                case .fallback(let text):
                    stopTyping()
                    updateAssistantMessage(id: placeholderID, text: text)
                case .limitReached(let text):
                    stopTyping()
                    updateAssistantMessage(id: placeholderID, text: text)
                case .finished(let result):
                    stopTyping()
                    updateAssistantMessage(id: placeholderID, text: result.reply)
                    lastToolTrace = result.trace
                }
            }
        } catch {
            stopTyping()
            updateAssistantMessage(id: placeholderID, text: "⚠️ 调用失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 打字动画

    private var typingPending = ""
    private var typingTask: Task<Void, Never>?

    /// 启动(或延续)打字渲染:每帧从缓冲区取少量字符追加到显示文本
    private func pumpTyping(placeholderID: UUID) {
        guard typingTask == nil else { return }
        typingTask = Task {
            while !typingPending.isEmpty {
                let take = min(typingPending.count, 3)  // 每帧 3 字符
                let batch = String(typingPending.prefix(take))
                typingPending.removeFirst(take)
                if let last = messages.last(where: { $0.id == placeholderID }),
                   case .text(let current) = last.content {
                    updateAssistantMessage(id: placeholderID, text: current + batch)
                }
                try? await Task.sleep(for: .milliseconds(24))
            }
            typingTask = nil
        }
    }

    /// 结束打字:取消动画,清空残留缓冲区
    private func stopTyping() {
        typingTask?.cancel()
        typingTask = nil
        typingPending = ""
    }

    private func updateAssistantMessage(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        // 只更新文本,保留 fileAttachments 等字段(否则工具卡片会被冲掉)
        var message = messages[index]
        message.content = .text(text)
        messages[index] = message
    }

    /// 持久化配置与 API Key
    func saveConfig() {
        try? configStore.save(config)
        try? keychain.setString(apiKey, forKey: "llm.api_key")
    }

    /// 清空当前对话(仅内存,历史仍保留在 checkpoint 中可刷新恢复)
    func clearMessages() {
        typingTask?.cancel()
        typingTask = nil
        typingPending = ""
        messages = []
    }

    var availablePersonas: [Persona] {
        personas.listPersonas()
    }

    // MARK: - 记忆管理

    var memories: [MemoryItem] = []

    func loadMemories() {
        memories = (try? store.listMemories(persona: selectedPersona, kind: "long_term")) ?? []
    }

    func addMemory(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? store.addMemory(persona: selectedPersona, content: trimmed, kind: "long_term")
        loadMemories()
    }

    func deleteMemory(_ memory: MemoryItem) {
        try? store.deleteMemory(id: memory.id)
        loadMemories()
    }
}
