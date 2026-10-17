import Foundation
import LocalAuthentication
import Observation
import HiveHarnessCore

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
    var usageStats: UsageStats = .zero
    var lastRunUsage: LLMUsage = .zero
    /// 等待用户处理的审批请求
    var pendingApproval: ApprovalRequest?
    var pendingQuestion: ClarificationRequest?
    /// 当前人格下的会话列表
    var sessions: [SessionRecord] = []
    /// 当前会话 id
    var currentThreadID: String = ""
    /// 撤销后回填到输入框的草稿
    var pendingDraft: String?
    /// 已安装技能(内置 + 用户)
    var skills: [Skill] = []
    /// 待审技能提案
    var skillProposals: [SkillProposal] = []
    /// 当前会话的运行日志
    var runs: [RunRecord] = []
    /// 自上次进化以来累计的工具迭代次数(Hermes 风格节流)
    private var toolIterationsSinceEvolution = 0
    /// 本地 OpenAI 兼容网关
    var gatewayRunning = false
    var gatewayPort: Int?
    var gatewayError: String?
    private var gatewayServer: LocalGateway?

    // MARK: - 依赖

    let store: SQLiteStore
    let workspace: URL
    let workspaceService: WorkspaceService
    let mcpDirectory: URL
    let skillsDirectory: URL
    let personasDirectory: URL
    private let configStore: ConfigStore
    private let keychain: KeychainStore
    private let personas: PersonaStore
    private let mcpRegistry: MCPRegistry
    let skillStore: SkillStore
    let skillEvolver: SkillEvolver
    private var marketplace: MarketplaceService
    private var marketplaceInstaller: MarketplaceInstaller

    // MARK: - 审批内部状态

    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var approvalTimeout: Task<Void, Never>?
    private var questionContinuation: CheckedContinuation<ClarificationAnswer, Never>?
    private var questionTimeout: Task<Void, Never>?
    /// “始终允许”去重集合(应用会话内有效)
    private var autoApproved: Set<String> = []

    init() {
        // 数据目录:~/Library/Application Support/HiveHarness/
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("HiveHarness", isDirectory: true)
        let legacyBase = appSupport.appendingPathComponent("ShizukuClaw", isDirectory: true)
        if !fm.fileExists(atPath: base.path), fm.fileExists(atPath: legacyBase.path) {
            try? fm.copyItem(at: legacyBase, to: base)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)

        configStore = ConfigStore(fileURL: base.appendingPathComponent("config.json"))
        let newKeychain = KeychainStore(service: "com.hiveharness.app")
        keychain = newKeychain
        // 工作区放在用户可见的 Documents/HiveHarness/(Application Support 深处用户找不到)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let ws = documents.appendingPathComponent("HiveHarness", isDirectory: true)
        let legacyWorkspaceRoot = documents.appendingPathComponent("ShizukuClaw", isDirectory: true)
        if !fm.fileExists(atPath: ws.path), fm.fileExists(atPath: legacyWorkspaceRoot.path) {
            try? fm.copyItem(at: legacyWorkspaceRoot, to: ws)
        }
        workspace = ws
        workspaceService = WorkspaceService(root: ws)
        try? fm.createDirectory(at: ws, withIntermediateDirectories: true)

        // 用户人格目录:~/Documents/HiveHarness/personas/<id>.json
        let personaDir = ws.appendingPathComponent("personas", isDirectory: true)
        try? FileManager.default.createDirectory(at: personaDir, withIntermediateDirectories: true)
        personasDirectory = personaDir
        personas = PersonaStore(userDirectory: personaDir)

        // MCP 配置目录:~/Documents/HiveHarness/mcp/servers.json
        let mcpDir = ws.appendingPathComponent("mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
        mcpDirectory = mcpDir
        mcpRegistry = MCPRegistry(configs: MCPConfigLoader.load(directory: mcpDir))

        // 用户技能目录:~/Documents/HiveHarness/skills/<id>/SKILL.md
        let skillsDir = ws.appendingPathComponent("skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        skillsDirectory = skillsDir
        skillStore = SkillStore(userDirectory: skillsDir)
        skillEvolver = SkillEvolver(skillsDirectory: skillsDir)

        // 不在启动时读取钥匙串,避免每次重建签名后弹系统授权框;需要时再读。
        marketplace = MarketplaceService(githubToken: "")
        marketplaceInstaller = MarketplaceInstaller(githubToken: "", skillStore: skillStore, mcpDirectory: mcpDir)

        // 迁移旧工作区文件(Application Support/workspace -> Documents/HiveHarness)
        let legacyWorkspace = base.appendingPathComponent("workspace", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyWorkspace.path) {
            if let legacyFiles = try? FileManager.default.contentsOfDirectory(atPath: legacyWorkspace.path) {
                for file in legacyFiles {
                    let src = legacyWorkspace.appendingPathComponent(file)
                    let dst = ws.appendingPathComponent(file)
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
        // 旧钥匙串迁移(旧 bundle id 服务名 -> 新服务名)
        let legacyKeychain = KeychainStore(service: "com.shizukuclaw.app")
        var legacyKeys = ["llm.api_key", "github.token"]
        legacyKeys.append(contentsOf: loadedConfig.providers.keys.map { "provider.\($0).api_key" })
        for key in legacyKeys {
            let existing = (try? newKeychain.string(forKey: key)) ?? nil
            if existing == nil, let value = (try? legacyKeychain.string(forKey: key)) ?? nil, !value.isEmpty {
                try? newKeychain.setString(value, forKey: key)
            }
        }

        apiKey = ""
        selectedPersona = loadedConfig.agent.defaultPersona
        store = try! SQLiteStore(path: base.appendingPathComponent("agent.db").path)

        loadSessions()
        if personas.load(id: selectedPersona) == nil {
            selectedPersona = personas.defaultPersona()?.id ?? "assistant"
        }
        skills = skillStore.all()
        skillProposals = skillEvolver.proposals()

        if config.gateway.enabled {
            Task { [weak self] in
                await self?.startGateway()
            }
        }
    }

    var threadID: String {
        currentThreadID.isEmpty ? "persona:\(selectedPersona)" : currentThreadID
    }

    /// 从存储恢复当前人格的对话历史、任务计划与上下文状态
    func loadHistory() {
        messages = (try? store.loadMessages(threadID: threadID, persona: selectedPersona)) ?? []
        taskPlan = (try? store.loadTaskPlan(threadID: threadID, persona: selectedPersona)) ?? .empty
        contextState = (try? store.loadContextState(threadID: threadID, persona: selectedPersona)) ?? .empty
        usageStats = loadUsageStats()
        lastRunUsage = .zero
        runs = (try? store.listRuns(
            threadID: threadID,
            persona: selectedPersona,
            limit: 100
        )) ?? []
    }

    func loadRuns() {
        runs = (try? store.listRuns(
            threadID: threadID,
            persona: selectedPersona,
            limit: 100
        )) ?? []
    }

    func selectPersona(_ id: String) {
        selectedPersona = id
        loadSessions()
    }

    // MARK: - 会话

    /// 载入当前人格的会话列表;旧版 `persona:<id>` 历史会自动登记为“历史会话”。
    func loadSessions() {
        var list = (try? store.listSessions(persona: selectedPersona)) ?? []
        if list.isEmpty {
            let legacyID = "persona:\(selectedPersona)"
            let legacyMessages = (try? store.loadMessages(
                threadID: legacyID,
                persona: selectedPersona
            )) ?? []
            if !legacyMessages.isEmpty {
                let record = SessionRecord(
                    id: legacyID,
                    persona: selectedPersona,
                    title: "历史会话",
                    preview: legacyMessages.last?.content.plainText ?? ""
                )
                try? store.upsertSession(record)
                list = [record]
            }
        }
        if list.isEmpty {
            let record = SessionRecord(
                id: "s_" + UUID().uuidString.lowercased(),
                persona: selectedPersona,
                title: "新会话"
            )
            try? store.upsertSession(record)
            list = [record]
        }
        sessions = list
        if let first = list.first {
            currentThreadID = first.id
        }
        loadHistory()
    }

    func newSession() {
        let record = SessionRecord(
            id: "s_" + UUID().uuidString.lowercased(),
            persona: selectedPersona,
            title: "新会话"
        )
        try? store.upsertSession(record)
        sessions = (try? store.listSessions(persona: selectedPersona)) ?? [record]
        currentThreadID = record.id
        messages = []
        taskPlan = .empty
        contextState = .empty
        lastToolTrace = []
        pendingDraft = nil
    }

    func selectSession(_ id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        currentThreadID = id
        lastToolTrace = []
        loadHistory()
    }

    /// 复制当前可见消息到独立会话(重新生成消息 id)。
    func forkCurrentSession() {
        let source = (try? store.listSessions(persona: selectedPersona))?
            .first { $0.id == currentThreadID }
        let sourceMessages = (try? store.loadMessages(
            threadID: currentThreadID,
            persona: selectedPersona
        )) ?? []
        guard !sourceMessages.isEmpty else {
            errorMessage = "当前会话为空,无法分叉"
            return
        }
        let target = "s_" + UUID().uuidString.lowercased()
        let copied = sourceMessages.map { message in
            ChatMessage(
                role: message.role,
                content: message.content,
                toolCalls: message.toolCalls,
                toolCallID: message.toolCallID,
                toolName: message.toolName,
                fileAttachments: message.fileAttachments
            )
        }
        try? store.saveMessages(threadID: target, persona: selectedPersona, messages: copied)
        let record = SessionRecord(
            id: target,
            persona: selectedPersona,
            title: (source?.title ?? "会话") + " · 分叉",
            preview: source?.preview ?? ""
        )
        try? store.upsertSession(record)
        sessions = (try? store.listSessions(persona: selectedPersona)) ?? [record]
        currentThreadID = target
        loadHistory()
    }

    /// 撤销最近一轮:删除该用户消息及其后的回复,把内容回填为草稿。
    func undoLastTurn() {
        let all = (try? store.loadMessages(threadID: threadID, persona: selectedPersona)) ?? []
        guard let index = all.lastIndex(where: { $0.role == .user }) else {
            errorMessage = "没有可撤销的用户消息"
            return
        }
        let kept = Array(all.prefix(index))
        try? store.saveMessages(threadID: threadID, persona: selectedPersona, messages: kept)
        try? store.deleteTaskPlan(threadID: threadID, persona: selectedPersona)
        try? store.deleteContextState(threadID: threadID, persona: selectedPersona)
        messages = kept
        taskPlan = .empty
        contextState = .empty
        lastToolTrace = []
        pendingDraft = all[index].content.plainText
        touchSession(userText: all[index].content.plainText, reply: "", threadID: threadID, persona: selectedPersona)
    }

    func clearCurrentSession() {
        try? store.saveMessages(threadID: threadID, persona: selectedPersona, messages: [])
        try? store.deleteTaskPlan(threadID: threadID, persona: selectedPersona)
        try? store.deleteContextState(threadID: threadID, persona: selectedPersona)
        messages = []
        taskPlan = .empty
        contextState = .empty
        usageStats = .zero
        lastRunUsage = .zero
        saveUsageStats()
        lastToolTrace = []
    }

    func deleteCurrentSession() {
        let deleting = currentThreadID
        try? store.deleteSession(threadID: deleting, persona: selectedPersona)
        sessions = (try? store.listSessions(persona: selectedPersona)) ?? []
        if let first = sessions.first {
            currentThreadID = first.id
            loadHistory()
        } else {
            newSession()
        }
    }

    /// 更新会话标题/预览与最近时间。
    private func touchSession(
        userText: String,
        reply: String,
        threadID: String,
        persona: String
    ) {
        let existing = (try? store.listSessions(persona: persona))?
            .first { $0.id == threadID }
        let now = Date()
        let trimmedUser = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let existing, existing.title != "新会话", !existing.title.isEmpty {
            title = existing.title
        } else {
            title = trimmedUser.isEmpty ? "新会话" : String(trimmedUser.prefix(24))
        }
        let preview = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let record = SessionRecord(
            id: threadID,
            persona: persona,
            title: title,
            preview: preview,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try? store.upsertSession(record)
        if persona == selectedPersona {
            sessions = (try? store.listSessions(persona: persona)) ?? sessions
        }
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

    /// Agent 主动澄清:挂起工具循环,等待 UI 选择/补充。
    func requestClarification(_ request: ClarificationRequest) async -> ClarificationAnswer {
        await withCheckedContinuation { continuation in
            questionContinuation = continuation
            pendingQuestion = request
            questionTimeout?.cancel()
            questionTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                self?.resolveQuestion(.cancelled)
            }
        }
    }

    /// 由问题卡片调用;跳过时传 .cancelled。
    func resolveQuestion(_ answer: ClarificationAnswer) {
        questionTimeout?.cancel()
        questionTimeout = nil
        pendingQuestion = nil
        questionContinuation?.resume(returning: answer)
        questionContinuation = nil
    }

    /// 发送消息并调用 Agent(无 API Key 时核心自动走本地回退)
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        let requestPersona = selectedPersona
        let requestThread = threadID

        messages.append(.text(.user, trimmed))
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        let mcpTools = await loadMCPTools()
        let loop = AgentLoop(
            store: store,
            config: config,
            keychain: keychain,
            personas: personas,
            workspace: workspace,
            approvalHandler: { [weak self] request in
                guard let self else { return .reject }
                return await self.requestApproval(request)
            },
            clarificationHandler: { [weak self] request in
                guard let self else { return .cancelled }
                return await self.requestClarification(request)
            },
            clarificationMode: config.agent.clarificationMode,
            extraTools: mcpTools + skillTools,
            skillCatalog: skillCatalogText
        )
        do {
            let result = try await loop.invoke(
                message: trimmed,
                persona: requestPersona,
                threadID: requestThread
            )
            if requestThread == currentThreadID {
                messages.append(.text(.assistant, result.reply))
                lastToolTrace = result.trace
                taskPlan = (try? store.loadTaskPlan(threadID: requestThread, persona: requestPersona)) ?? .empty
                contextState = (try? store.loadContextState(threadID: requestThread, persona: requestPersona)) ?? .empty
            }
            if requestThread == currentThreadID {
                recordUsage(
                    result.usage,
                    modelCalls: result.modelCalls,
                    toolCalls: result.trace.count
                )
            }
            touchSession(
                userText: trimmed,
                reply: result.reply,
                threadID: requestThread,
                persona: requestPersona
            )
            maybeEvolve(
                AgentTrajectory(
                    userMessage: trimmed,
                    reply: result.reply,
                    persona: requestPersona,
                    threadID: requestThread,
                    traces: result.trace
                ),
                loop: loop
            )
        } catch {
            errorMessage = "调用失败: \(error.localizedDescription)"
        }
    }

    /// 流式发送:文本增量实时更新最后一条助手消息(打字机效果)
    func sendStreaming(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        let requestPersona = selectedPersona
        let requestThread = threadID
        var streamedReply = ""

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
            if pendingQuestion != nil {
                resolveQuestion(.cancelled)
            }
            touchSession(
                userText: trimmed,
                reply: streamedReply,
                threadID: requestThread,
                persona: requestPersona
            )
            isBusy = false
        }

        // 占位助手消息,流式期间原地更新
        let placeholderID = UUID()
        messages.append(ChatMessage(role: .assistant, content: .text(""), id: placeholderID))

        let mcpTools = await loadMCPTools()
        let loop = AgentLoop(
            store: store,
            config: config,
            keychain: keychain,
            personas: personas,
            workspace: workspace,
            approvalHandler: { [weak self] request in
                guard let self else { return .reject }
                return await self.requestApproval(request)
            },
            clarificationHandler: { [weak self] request in
                guard let self else { return .cancelled }
                return await self.requestClarification(request)
            },
            clarificationMode: config.agent.clarificationMode,
            extraTools: mcpTools + skillTools,
            skillCatalog: skillCatalogText
        )
        do {
            for try await event in await loop.stream(
                message: trimmed,
                persona: requestPersona,
                threadID: requestThread
            ) {
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
                    if requestThread == currentThreadID { taskPlan = plan }
                case .contextUpdated(let context):
                    if requestThread == currentThreadID { contextState = context }
                case .fallback(let text):
                    stopTyping()
                    streamedReply = text
                    updateAssistantMessage(id: placeholderID, text: text)
                case .limitReached(let text):
                    stopTyping()
                    streamedReply = text
                    updateAssistantMessage(id: placeholderID, text: text)
                case .finished(let result):
                    stopTyping()
                    streamedReply = result.reply
                    if requestThread == currentThreadID {
                        recordUsage(
                            result.usage,
                            modelCalls: result.modelCalls,
                            toolCalls: result.trace.count
                        )
                    }
                    updateAssistantMessage(id: placeholderID, text: result.reply)
                    if requestThread == currentThreadID {
                        lastToolTrace = result.trace
                        taskPlan = (try? store.loadTaskPlan(threadID: requestThread, persona: requestPersona)) ?? .empty
                        contextState = (try? store.loadContextState(threadID: requestThread, persona: requestPersona)) ?? .empty
                        runs = (try? store.listRuns(
                            threadID: requestThread,
                            persona: requestPersona,
                            limit: 100
                        )) ?? []
                    }
                    maybeEvolve(
                        AgentTrajectory(
                            userMessage: trimmed,
                            reply: result.reply,
                            persona: requestPersona,
                            threadID: requestThread,
                            traces: result.trace
                        ),
                        loop: loop
                    )
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
        if !apiKey.isEmpty {
            try? keychain.setString(apiKey, forKey: "llm.api_key")
        }
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

    // MARK: - MCP

    /// 连接启用的 MCP 服务器并返回工具适配器;单个服务器失败会被跳过。
    func loadMCPTools() async -> [any Tool] {
        (try? await mcpRegistry.makeAdapters()) ?? []
    }

    /// 重新读取 `mcp/servers.json` 并重建连接。
    func reloadMCPConfigs() async {
        let configs = MCPConfigLoader.load(directory: mcpDirectory)
        await mcpRegistry.reload(configs: configs)
    }

    // MARK: - 技能

    private var skillTools: [any Tool] {
        [
            SkillTools.ListSkillsTool(store: skillStore),
            SkillTools.RunSkillTool(store: skillStore),
        ]
    }

    /// 渐进披露:只把 id/name/description 放进 system prompt。
    private var skillCatalogText: String {
        skills
            .filter(\.enabled)
            .map { "- \($0.id): \($0.name) — \(String($0.description.prefix(80)))" }
            .joined(separator: "\n")
    }

    func reloadSkills() {
        skillStore.reload()
        skills = skillStore.all()
    }

    func setSkillEnabled(_ id: String, enabled: Bool) {
        skillStore.setEnabled(enabled, id: id)
        skills = skillStore.all()
    }

    /// 归档 30 天未用的用户技能(移到 skills/_archive)。
    func archiveStaleSkills() {
        _ = skillStore.archiveStale(days: 30)
        skills = skillStore.all()
    }

    func skillVersions(_ id: String) -> [SkillVersion] {
        skillStore.versions(id: id)
    }

    func backupSkill(_ id: String) {
        _ = skillStore.backup(id: id)
    }

    func rollbackSkill(_ id: String, version: String) {
        try? skillStore.rollback(id: id, version: version)
        reloadSkills()
    }

    func checkSkillUpdate(_ skill: Skill) async throws -> MarketplaceUpdateStatus {
        try await marketplaceInstaller.checkUpdate(for: skill)
    }

    /// 依次检查所有市场安装技能;单个失败标记 unknown,不中断批量检查。
    func checkAllSkillUpdates() async -> [String: MarketplaceUpdateStatus] {
        var result: [String: MarketplaceUpdateStatus] = [:]
        for skill in skills where skill.marketplace != nil {
            do {
                result[skill.id] = try await marketplaceInstaller.checkUpdate(for: skill)
            } catch {
                result[skill.id] = .unknown
            }
        }
        return result
    }

    func updateSkill(_ skill: Skill) async throws -> [Skill] {
        let installed = try await marketplaceInstaller.update(skill)
        skills = skillStore.all()
        return installed
    }

    @discardableResult
    func installSkill(from url: URL) throws -> Skill {
        let skill = try skillStore.install(from: url)
        skills = skillStore.all()
        return skill
    }

    // MARK: - 技能自进化

    func reloadSkillProposals() {
        skillProposals = skillEvolver.proposals()
    }

    func approveSkillProposal(_ proposal: SkillProposal) {
        _ = try? skillEvolver.approve(proposal)
        reloadSkills()
        reloadSkillProposals()
    }

    func rejectSkillProposal(_ proposal: SkillProposal) {
        try? skillEvolver.reject(proposal)
        reloadSkillProposals()
    }

    /// 每累计 10 次工具迭代触发一次反思生成技能提案(Hermes 风格节流)。
    private func maybeEvolve(_ trajectory: AgentTrajectory, loop: AgentLoop) {
        guard config.agent.autoEvolveSkills else { return }
        toolIterationsSinceEvolution += trajectory.traces.count
        guard toolIterationsSinceEvolution >= 10 else { return }
        toolIterationsSinceEvolution = 0

        let existing = skills
        Task { [weak self] in
            guard let self else { return }
            let proposal = await self.skillEvolver.consider(
                trajectory: trajectory,
                existingSkills: existing,
                reflect: { system, user in
                    try await loop.complete(prompt: user, system: system)
                }
            )
            if let proposal {
                self.skillProposals = self.skillEvolver.proposals()
                self.errorMessage = "已生成技能提案: \(proposal.name)(在设置 → 技能中批准)"
            }
        }
    }

    // MARK: - AI 用量

    private var usageKVKey: String { "usage.\(threadID)" }

    private func loadUsageStats() -> UsageStats {
        guard let value = try? store.getKV(key: usageKVKey),
              let dict = value.value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let stats = try? JSONDecoder().decode(UsageStats.self, from: data)
        else { return .zero }
        return stats
    }

    private func saveUsageStats() {
        guard let data = try? JSONEncoder().encode(usageStats),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return }
        try? store.setKV(key: usageKVKey, value: AnyCodable(object))
    }

    func recordUsage(_ usage: LLMUsage, modelCalls: Int, toolCalls: Int) {
        usageStats.record(usage, modelCalls: modelCalls, toolCalls: toolCalls)
        lastRunUsage = usage
        saveUsageStats()
    }

    func resetUsageStats() {
        usageStats = .zero
        lastRunUsage = .zero
        saveUsageStats()
    }

    // MARK: - 插件市场

    var githubToken: String {
        (try? keychain.string(forKey: "github.token")) ?? ""
    }

    func setGitHubToken(_ token: String) {
        try? keychain.setString(token, forKey: "github.token")
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        marketplace = MarketplaceService(githubToken: trimmed)
        marketplaceInstaller = MarketplaceInstaller(githubToken: trimmed, skillStore: skillStore, mcpDirectory: mcpDirectory)
    }

    func searchMarketplace(
        query: String,
        source: MarketplaceSource?,
        page: Int = 1
    ) async -> MarketplaceResult {
        await marketplace.feed(query: query, source: source, page: page)
    }

    func importMarketplaceLink(_ raw: String) async throws -> MarketplaceItem {
        try await marketplace.importLink(raw)
    }

    func expandMarketplaceItem(_ item: MarketplaceItem) async throws -> [MarketplaceItem] {
        try await marketplace.expand(item: item)
    }

    func planMarketplaceInstall(_ item: MarketplaceItem) async throws -> MarketplaceInstallPlan {
        try await marketplaceInstaller.plan(for: item)
    }

    @discardableResult
    func installMarketplacePlan(_ plan: MarketplaceInstallPlan) throws -> [Skill] {
        let installed = try marketplaceInstaller.install(plan)
        skills = skillStore.all()
        return installed
    }

    // MARK: - 本地网关

    var gatewayBaseURL: String {
        "http://127.0.0.1:\(gatewayPort ?? config.gateway.port)/v1"
    }

    func startGateway() async {
        guard !gatewayRunning else { return }
        let normalized = config.normalized()
        let modelIDs = normalized.models.keys.sorted()
        let token = normalized.gateway.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let router = GatewayRouter(
            models: { modelIDs },
            token: token.isEmpty ? nil : token,
            chat: { [weak self] request in
                guard let self else {
                    return GatewayChatResult(reply: "App 已退出", model: "unavailable")
                }
                return await self.handleGatewayChat(request)
            },
            streamChat: { [weak self] request in
                AsyncThrowingStream { continuation in
                    Task { @MainActor in
                        guard let self else {
                            continuation.finish()
                            return
                        }
                        do {
                            for try await event in self.gatewayStream(request) {
                                continuation.yield(event)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
        )
        let server = LocalGateway(router: router)
        do {
            let port = try await server.start(port: UInt16(clamping: normalized.gateway.port))
            gatewayServer = server
            gatewayPort = Int(port)
            gatewayRunning = true
            gatewayError = nil
            config.gateway.enabled = true
            saveConfig()
        } catch {
            gatewayError = error.localizedDescription
            gatewayRunning = false
            gatewayPort = nil
        }
    }

    func stopGateway() async {
        await gatewayServer?.stop()
        gatewayServer = nil
        gatewayRunning = false
        gatewayPort = nil
        config.gateway.enabled = false
        saveConfig()
    }

    /// 网关流式请求:逐 token 产出,结束携带用量。
    private func gatewayStream(
        _ request: GatewayChatRequest
    ) -> AsyncThrowingStream<GatewayStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let persona = request.persona ?? self.config.gateway.defaultPersona
                let thread = request.threadID ?? ("gateway_" + UUID().uuidString.lowercased())
                let mcpTools = await self.loadMCPTools()
                let loop = AgentLoop(
                    store: self.store,
                    config: self.config,
                    keychain: self.keychain,
                    personas: self.personas,
                    workspace: self.workspace,
                    approvalHandler: { _ in .reject },
                    extraTools: mcpTools + self.skillTools,
                    skillCatalog: self.skillCatalogText
                )
                do {
                    var model = self.config.llm.model
                    for try await event in await loop.stream(
                        message: request.message,
                        persona: persona,
                        threadID: thread
                    ) {
                        switch event {
                        case .chunk(let delta):
                            continuation.yield(.delta(delta))
                        case .finished(let result):
                            model = result.activeModel.isEmpty
                                ? self.config.llm.model
                                : result.activeModel
                            continuation.yield(.finished(
                                model: model,
                                reply: result.reply,
                                promptTokens: TokenEstimator.estimate(request.message),
                                completionTokens: TokenEstimator.estimate(result.reply)
                            ))
                            continuation.finish()
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 网关请求:独立会话,外部写入/执行一律拒绝审批。
    private func handleGatewayChat(_ request: GatewayChatRequest) async -> GatewayChatResult {
        let persona = request.persona ?? config.gateway.defaultPersona
        let thread = request.threadID ?? ("gateway_" + UUID().uuidString.lowercased())
        let mcpTools = await loadMCPTools()
        let loop = AgentLoop(
            store: store,
            config: config,
            keychain: keychain,
            personas: personas,
            workspace: workspace,
            approvalHandler: { _ in .reject },
            extraTools: mcpTools + skillTools,
            skillCatalog: skillCatalogText
        )
        do {
            let result = try await loop.invoke(
                message: request.message,
                persona: persona,
                threadID: thread
            )
            let model = result.activeModel.isEmpty ? config.llm.model : result.activeModel
            return GatewayChatResult(
                reply: result.reply,
                model: model,
                promptTokens: TokenEstimator.estimate(request.message),
                completionTokens: TokenEstimator.estimate(result.reply)
            )
        } catch {
            return GatewayChatResult(
                reply: "网关调用失败: \(error.localizedDescription)",
                model: "error"
            )
        }
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

    func personaIsBuiltin(_ id: String) -> Bool {
        personas.isBuiltin(id: id)
    }

    func personaIsCustomized(_ id: String) -> Bool {
        personas.isCustomized(id: id)
    }

    func savePersona(_ persona: Persona) {
        do {
            try personas.save(persona)
            if personas.load(id: selectedPersona) == nil {
                selectedPersona = personas.defaultPersona()?.id ?? "assistant"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePersona(_ id: String) {
        do {
            try personas.delete(id: id)
            if selectedPersona == id {
                selectedPersona = personas.defaultPersona()?.id ?? "assistant"
                loadHistory()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetPersona(_ id: String) {
        do {
            try personas.resetBuiltin(id: id)
            if selectedPersona == id {
                loadHistory()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 记忆管理

    var memories: [MemoryItem] = []

    func loadMemories() {
        memories = (try? store.listMemories(persona: selectedPersona, kind: "long_term")) ?? []
    }

    func updateMemory(_ memory: MemoryItem, content: String, confidence: Double) {
        _ = try? store.updateMemory(id: memory.id, content: content, confidence: confidence)
        loadMemories()
    }

    func addMemory(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? store.addMemory(persona: selectedPersona, content: trimmed, kind: "long_term", sourceKind: "manual", confidence: 1.0)
        loadMemories()
    }

    func deleteMemory(_ memory: MemoryItem) {
        try? store.deleteMemory(id: memory.id)
        loadMemories()
    }
}
