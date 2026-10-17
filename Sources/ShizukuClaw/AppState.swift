import Foundation
import LocalAuthentication
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
    /// 当前会话的任务计划(todowrite 实时更新)
    var taskPlan: TaskPlan = .empty
    /// 当前会话的上下文用量/压缩状态
    var contextState: SessionContextState = .empty
    /// 等待用户处理的审批请求
    var pendingApproval: ApprovalRequest?

    // MARK: - 依赖

    let store: SQLiteStore
    let workspace: URL
    private let configStore: ConfigStore
    private let keychain: KeychainStore
    private let personas: PersonaStore

    // MARK: - 审批内部状态

    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var approvalTimeout: Task<Void, Never>?
    /// “始终允许”去重集合(应用会话内有效)
    private var autoApproved: Set<String> = []

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
        let normalized = loadedConfig.normalized()
        config = normalized
        if normalized != loadedConfig {
            try? configStore.save(normalized)
        }
        apiKey = (try? keychain.string(forKey: "llm.api_key")) ?? ""
        selectedPersona = loadedConfig.agent.defaultPersona
        store = try! SQLiteStore(path: base.appendingPathComponent("agent.db").path)

        loadHistory()
    }

    var threadID: String { "persona:\(selectedPersona)" }

    /// 从存储恢复当前人格的对话历史、任务计划与上下文状态
    func loadHistory() {
        messages = (try? store.loadMessages(threadID: threadID, persona: selectedPersona)) ?? []
        taskPlan = (try? store.loadTaskPlan(threadID: threadID, persona: selectedPersona)) ?? .empty
        contextState = (try? store.loadContextState(threadID: threadID, persona: selectedPersona)) ?? .empty
    }

    func selectPersona(_ id: String) {
        selectedPersona = id
        loadHistory()
    }

    // MARK: - 工作模式与审批

    /// 切换工作模式;进入完全控制前必须通过系统身份验证(Touch ID / 登录密码)。
    func setWorkMode(_ mode: WorkMode) async {
        guard mode != config.agent.workMode else { return }
        if mode == .full {
            guard await authenticate(reason: "切换到完全控制模式,允许 Agent 写入工作区外文件并执行本机命令") else {
                errorMessage = "身份验证未通过,工作模式保持不变"
                return
            }
        }
        config.agent.workMode = mode
        saveConfig()
        errorMessage = nil
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 没有可用的生物认证/密码时,不允许进入完全控制
            errorMessage = "此设备不支持系统身份验证,无法进入完全控制模式"
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    /// Agent 调用:等待用户在界面上选择一次/始终/拒绝。
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        if autoApproved.contains(request.key) { return .once }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = request
            approvalTimeout?.cancel()
            approvalTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.resolveApproval(.reject)
            }
        }
    }

    /// 由审批条按钮调用。
    func resolveApproval(_ decision: ApprovalDecision) {
        approvalTimeout?.cancel()
        approvalTimeout = nil
        if decision == .always, let request = pendingApproval {
            autoApproved.insert(request.key)
        }
        pendingApproval = nil
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
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
            workspace: workspace,
            approvalHandler: { [weak self] request in
                guard let self else { return .reject }
                return await self.requestApproval(request)
            }
        )
        do {
            let result = try await loop.invoke(message: trimmed, persona: selectedPersona)
            messages.append(.text(.assistant, result.reply))
            lastToolTrace = result.trace
            taskPlan = (try? store.loadTaskPlan(threadID: threadID, persona: selectedPersona)) ?? .empty
            contextState = (try? store.loadContextState(threadID: threadID, persona: selectedPersona)) ?? .empty
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
        defer {
            // 流结束/取消时,未决审批一律按拒绝处理,避免 Agent 永久挂起
            if pendingApproval != nil {
                resolveApproval(.reject)
            }
            isBusy = false
        }

        // 占位助手消息,流式期间原地更新
        let placeholderID = UUID()
        messages.append(ChatMessage(role: .assistant, content: .text(""), id: placeholderID))

        let loop = AgentLoop(
            store: store,
            config: config,
            keychain: keychain,
            personas: personas,
            workspace: workspace,
            approvalHandler: { [weak self] request in
                guard let self else { return .reject }
                return await self.requestApproval(request)
            }
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
                case .planUpdated(let plan):
                    taskPlan = plan
                case .contextUpdated(let context):
                    contextState = context
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
                    taskPlan = (try? store.loadTaskPlan(threadID: threadID, persona: selectedPersona)) ?? .empty
                    contextState = (try? store.loadContextState(threadID: threadID, persona: selectedPersona)) ?? .empty
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

    // MARK: - 模型配置

    /// 默认模型组首个模型的可读名称(顶栏展示)。
    var activeModelName: String {
        let normalized = config.normalized()
        guard let group = normalized.modelGroups[normalized.defaultModelGroup],
              let modelID = group.models.first,
              let model = normalized.models[modelID]
        else { return config.llm.model }
        let provider = normalized.providers[model.provider]?.name ?? model.provider
        return "\(provider) / \(model.name)"
    }

    func providerKey(_ providerID: String) -> String {
        (try? keychain.string(forKey: ModelRegistry.apiKeyKey(providerID: providerID))) ?? ""
    }

    func setProviderKey(_ key: String, providerID: String) {
        try? keychain.setString(key, forKey: ModelRegistry.apiKeyKey(providerID: providerID))
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
