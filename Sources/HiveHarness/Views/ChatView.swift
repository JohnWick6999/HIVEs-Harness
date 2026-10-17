import SwiftUI
import HiveHarnessCore

struct ChatView: View {
    @Environment(AppState.self) private var state
    @State private var input = ""
    @State private var showSettings = false
    @State private var showMarketplace = false
    @State private var showWorkbench = false
    @State private var showRunHistory = false
    @State private var planExpanded = true
    @State private var showContext = false
    @FocusState private var composerFocused: Bool
    @State private var showUsage = false

    var body: some View {
        @Bindable var state = state
        ZStack {
            HiveBackground()
            VStack(spacing: 0) {
                header
                if !state.taskPlan.items.isEmpty {
                    planPanel
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                messageList
                if let question = state.pendingQuestion {
                    HiveQuestionCard(
                        question: question,
                        onAnswer: { state.resolveQuestion($0) },
                        onSkip: { state.resolveQuestion(.cancelled) }
                    )
                    .id(question.id)
                    .animation(.spring(response: 0.35, dampingFraction: 0.86), value: question.id)
                }
                if let approval = state.pendingApproval {
                    approvalBar(approval)
                }
                inputBar
                usageBar
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(state)
        }
        .sheet(isPresented: $showMarketplace) {
            MarketplaceView()
                .environment(state)
        }
        .sheet(isPresented: $showWorkbench) {
            WorkbenchView()
                .environment(state)
        }
        .sheet(isPresented: $showRunHistory) {
            RunHistoryView()
                .environment(state)
        }
        .sheet(isPresented: $state.showPluginStudio) {
            PluginStudioView()
                .environment(state)
        }
        .tint(HiveTheme.amberDeep)
        .onChange(of: state.pendingDraft) { _, draft in
            guard let draft else { return }
            input = draft
            state.pendingDraft = nil
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 9) {
            HiveMark(size: 24)

            Menu {
                ForEach(state.availablePersonas) { persona in
                    Button {
                        state.selectPersona(persona.id)
                    } label: {
                        if persona.id == state.selectedPersona {
                            Label(persona.meta.name, systemImage: "checkmark")
                        } else {
                            Text(persona.meta.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle")
                    Text(personaName)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            sessionMenu

            modeMenu

            Text(state.activeModelName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            contextIndicator

            if state.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text("思考中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                showRunHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("运行日志")

            Button {
                showWorkbench = true
            } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .help("工作台")

            Button {
                showMarketplace = true
            } label: {
                Image(systemName: "storefront")
            }
            .help("插件市场")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(HiveTheme.hairline)
                .frame(height: 1)
        }
    }

    private var personaName: String {
        state.availablePersonas.first { $0.id == state.selectedPersona }?.meta.name
            ?? state.selectedPersona
    }

    // MARK: - 会话

    private var sessionMenu: some View {
        Menu {
            Button("新建会话") { state.newSession() }
            Divider()
            ForEach(state.sessions) { session in
                Button {
                    state.selectSession(session.id)
                } label: {
                    if session.id == state.currentThreadID {
                        Label(session.title, systemImage: "checkmark")
                    } else {
                        Text(session.title)
                    }
                }
            }
            Divider()
            Button("分叉当前会话") { state.forkCurrentSession() }
            Button("撤销上一轮") { state.undoLastTurn() }
            Button("清空当前会话") { state.clearCurrentSession() }
            Button("删除当前会话", role: .destructive) { state.deleteCurrentSession() }
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("会话")
    }

    // MARK: - 工作模式与审批

    private var modeMenu: some View {
        Menu {
            ForEach(WorkMode.allCases, id: \.rawValue) { mode in
                Button {
                    Task { await state.setWorkMode(mode) }
                } label: {
                    if mode == state.config.agent.workMode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: modeIcon)
                Text(state.config.agent.workMode.title)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(modeColor.opacity(0.12), in: Capsule())
            .foregroundStyle(modeColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(state.config.agent.workMode.detail)
    }

    private var modeIcon: String {
        switch state.config.agent.workMode {
        case .chat: return "bubble.left"
        case .sandbox: return "lock.shield"
        case .full: return "exclamationmark.shield"
        }
    }

    private var modeColor: Color {
        switch state.config.agent.workMode {
        case .chat: return .blue
        case .sandbox: return .green
        case .full: return .orange
        }
    }

    private func approvalBar(_ request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(request.kind.title)
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            Text(request.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("拒绝") { state.resolveApproval(.reject) }
                    .keyboardShortcut(.cancelAction)
                Button("始终允许") { state.resolveApproval(.always) }
                Button("允许一次") { state.resolveApproval(.once) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .hiveCard(padding: 10, corner: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.orange.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 上下文用量

    private var contextIndicator: some View {
        Group {
            if state.contextState.contextLimit > 0 {
                Button {
                    showContext.toggle()
                } label: {
                    HStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .stroke(.quaternary, lineWidth: 2.5)
                            Circle()
                                .trim(from: 0, to: min(1, max(0, state.contextState.displayPercent / 100)))
                                .stroke(usageColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 16, height: 16)
                        Text("\(Int(state.contextState.displayPercent.rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.contextState.isActualUsage ? "上下文用量(模型实际 usage)" : "上下文用量(本地估算)")
                .popover(isPresented: $showContext, arrowEdge: .bottom) {
                    contextPopover
                }
            }
        }
    }

    private var usageColor: Color {
        let usage = state.contextState.displayPercent
        if usage >= 85 { return .red }
        if usage >= 60 { return .orange }
        return .accentColor
    }

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("上下文用量")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("模型")
                    Text(state.contextState.model.isEmpty ? state.config.llm.model : state.contextState.model)
                }
                GridRow {
                    Text("窗口")
                    Text("\(state.contextState.contextLimit) tokens")
                }
                GridRow {
                    Text("可用预算")
                    Text("\(state.contextState.budget) tokens")
                }
                if let actual = state.contextState.actualPromptTokens, actual > 0 {
                    GridRow {
                        Text("上次请求实际")
                        Text("\(actual) prompt + \(state.contextState.actualCompletionTokens ?? 0) output")
                            .monospacedDigit()
                    }
                }
                GridRow {
                    Text("本地估算")
                    Text("\(state.contextState.estimatedTokens) tokens")
                        .monospacedDigit()
                }
                GridRow {
                    Text("显示占用")
                    Text("\(state.contextState.displayTokens) / \(state.contextState.contextLimit) · \(String(format: "%.1f", state.contextState.displayPercent))%")
                        .monospacedDigit()
                }
                GridRow {
                    Text("摘要覆盖")
                    Text("\(state.contextState.coveredCount) 条消息")
                }
            }
            .font(.caption)

            Text(state.contextState.isActualUsage
                 ? "圆环优先使用模型返回的真实 prompt token;本地估算仅作兜底。"
                 : "当前模型未返回 usage,圆环使用本地估算;下一条消息后会自动校准。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.contextState.prunedTools > 0 {
                Text("本轮节选 \(state.contextState.prunedTools) 条超长工具结果")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if state.contextState.hasCompaction {
                Text("压缩摘要")
                    .font(.caption.weight(.semibold))
                ScrollView {
                    Text(state.contextState.summary)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 170)
                Text("原始消息仍完整保存在会话历史中;关闭提示后不会丢失。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("尚未触发压缩。达到可用预算的 85% 时,会保留最近两轮并自动生成交接摘要。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 350)
    }

    // MARK: - 任务计划

    private var planPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { planExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .foregroundStyle(.secondary)
                    Text("任务计划")
                        .font(.caption.weight(.semibold))
                    Text(state.taskPlan.progressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: planExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if planExpanded {
                ForEach(state.taskPlan.items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: statusIcon(item.status))
                            .font(.caption2)
                            .foregroundStyle(statusColor(item.status))
                        Text(item.content)
                            .font(.caption)
                            .strikethrough(item.status == .completed, color: .secondary)
                            .foregroundStyle(item.status == .completed ? .secondary : .primary)
                    }
                }
            }
        }
        .hiveCard(padding: 10, corner: 12)
    }

    private func statusIcon(_ status: TaskStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return .accentColor
        case .completed: return .green
        case .cancelled: return .secondary
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if state.messages.isEmpty {
                        emptyHint
                            .frame(minHeight: 500)
                    }
                    ForEach(state.messages) { message in
                        MessageRow(message: message, assistantName: personaName)
                            .id(message.id)
                    }
                    if !state.lastToolTrace.isEmpty {
                        toolTraceRow
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onChange(of: state.messages.last?.content.plainText) {
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 18) {
            HiveMark(size: 58)
            VStack(spacing: 6) {
                Text("把任务交给 HIVE")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("描述目标,HIVE 会判断是否需要工具、计划或向你提问。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(Self.suggestions.enumerated()), id: \.offset) { _, item in
                    Button {
                        input = item.prompt
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon)
                                    .foregroundStyle(HiveTheme.amberDeep)
                                Text(item.title)
                                    .font(.callout.weight(.semibold))
                            }
                            Text(item.prompt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                        .background(HiveTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(HiveTheme.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 520)
            Text("没有配置 API Key 时,HIVE's Harness 会以本地回退模式回复")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private static let suggestions: [(icon: String, title: String, prompt: String)] = [
        ("chevron.left.forwardslash.chevron.right", "审查代码", "审查当前工作区的代码,指出风险并给出可执行的修复建议。"),
        ("map", "规划项目", "帮我把这个目标拆成可执行的里程碑、任务和风险清单。"),
        ("magnifyingglass", "调研主题", "调研这个主题,优先一手来源,给出结论、证据和未知项。"),
        ("text.quote", "整理材料", "把下面的材料整理成结构清晰的简报,保留关键事实。"),
    ]

    private var toolTraceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(HiveTheme.amberDeep)
            Text("调用了 \(state.lastToolTrace.count) 个工具:\(state.lastToolTrace.map(\.tool).joined(separator: ", "))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(HiveTheme.card, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("交给 HIVE 一个任务…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit {
                        send()
                    }
                    .disabled(state.isBusy)

                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 2)
                }

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isBusy
                                ? AnyShapeStyle(Color.secondary.opacity(0.25))
                                : AnyShapeStyle(HiveTheme.gradient),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("发送 (Enter)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.62),
                in: RoundedRectangle(cornerRadius: HiveTheme.composerCorner, style: .continuous)
            )
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: HiveTheme.composerCorner, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HiveTheme.composerCorner, style: .continuous)
                    .stroke(
                        composerFocused ? HiveTheme.amber.opacity(0.55) : HiveTheme.hairline,
                        lineWidth: composerFocused ? 1.5 : 1
                    )
            )
            .shadow(color: .black.opacity(0.16), radius: 18, y: 5)

            HStack(spacing: 4) {
                Text("Enter 发送 · Shift+Enter 换行")
                Spacer()
                Text("\(input.count) 字")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - AI 用量

    private var usageBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(HiveTheme.amberDeep)
            Text("AI 用量")
                .fontWeight(.medium)
            Text("\(state.usageStats.totalTokens.formatted()) tok")
                .monospacedDigit()
            if state.usageStats.promptTokens > 0 {
                Text("缓存 \(cachePercent)%")
                    .monospacedDigit()
            }
            if state.lastRunUsage.totalTokens > 0 {
                Text("本次 \(state.lastRunUsage.totalTokens.formatted())")
                    .foregroundStyle(.tertiary)
            }
            Text("\(state.usageStats.modelCalls) 轮 · \(state.usageStats.runs) 次")
                .monospacedDigit()
            Spacer()
            Button {
                showUsage.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .help("查看 AI 用量明细")
            .popover(isPresented: $showUsage, arrowEdge: .bottom) {
                usagePopover
            }
            Menu {
                Button("查看用量明细") { showUsage = true }
                Button("复制统计") { copyUsage() }
                Divider()
                Button("清零当前会话统计", role: .destructive) {
                    state.resetUsageStats()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("AI 用量工具")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(HiveTheme.hairline)
                .frame(height: 1)
        }
    }

    private var cachePercent: String {
        String(format: "%.1f%%", state.usageStats.cacheHitRate * 100)
    }

    private var usagePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI 用量")
                    .font(.headline)
                Spacer()
                Button("清零") {
                    state.resetUsageStats()
                }
                .font(.caption)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    Text("Prompt")
                    Text("\(state.usageStats.promptTokens.formatted()) tok")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Completion")
                    Text("\(state.usageStats.completionTokens.formatted()) tok")
                        .monospacedDigit()
                }
                GridRow {
                    Text("总计")
                    Text("\(state.usageStats.totalTokens.formatted()) tok")
                        .monospacedDigit()
                }
                GridRow {
                    Text("缓存命中")
                    Text("\(state.usageStats.cachedTokens.formatted()) tok · \(cachePercent)")
                        .monospacedDigit()
                }
                GridRow {
                    Text("模型调用")
                    Text("\(state.usageStats.modelCalls) 轮")
                        .monospacedDigit()
                }
                GridRow {
                    Text("运行次数")
                    Text("\(state.usageStats.runs) 次")
                        .monospacedDigit()
                }
                GridRow {
                    Text("工具调用")
                    Text("\(state.usageStats.toolCalls) 次")
                        .monospacedDigit()
                }
                GridRow {
                    Text("平均每次")
                    Text("\(state.usageStats.averageTokensPerRun.formatted()) tok")
                        .monospacedDigit()
                }
            }
            .font(.caption)

            Divider()

            Text("按当前会话累计;缓存字段来自模型返回的 usage。数据保存在本地 SQLite。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 330)
    }

    private func copyUsage() {
        let text = """
        AI 用量(当前会话)
        Prompt: \(state.usageStats.promptTokens)
        Completion: \(state.usageStats.completionTokens)
        Total: \(state.usageStats.totalTokens)
        Cached: \(state.usageStats.cachedTokens)
        缓存命中率: \(cachePercent)
        模型调用: \(state.usageStats.modelCalls)
        运行次数: \(state.usageStats.runs)
        工具调用: \(state.usageStats.toolCalls)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func send() {
        let text = input
        input = ""
        Task {
            await state.sendStreaming(text)
        }
    }
}

// MARK: - 消息行

struct MessageRow: View {
    let message: ChatMessage
    let assistantName: String

    var body: some View {
        if message.role == .user {
            userRow
        } else if message.role == .assistant {
            assistantRow
        } else {
            systemRow
        }
    }

    private var userRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 4) {
                bubble(text: message.content.plainText, isUser: true)
                Text("你")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 9) {
            HiveMark(size: 25)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(assistantName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("HIVE")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(HiveTheme.amber.opacity(0.14), in: Capsule())
                        .foregroundStyle(HiveTheme.amberDeep)
                }
                if message.content.plainText.isEmpty {
                    Text("正在思考…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    bubble(text: message.content.plainText, isUser: false)
                }
                attachments
            }
            Spacer(minLength: 40)
        }
    }

    private var systemRow: some View {
        HStack {
            Image(systemName: "info.circle")
            Text(message.content.plainText)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(HiveTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func bubble(text: String, isUser: Bool) -> some View {
        bubbleContent(text, isUser: isUser)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isUser ? HiveTheme.userBubble : HiveTheme.assistantBubble,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isUser ? HiveTheme.amber.opacity(0.20) : HiveTheme.hairline,
                        lineWidth: 1
                    )
            )
    }

    @ViewBuilder
    private func bubbleContent(_ text: String, isUser: Bool) -> some View {
        if isUser {
            Text(text)
                .font(.system(.body, design: .rounded))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HiveMarkdownView(text: text)
        }
    }

    @ViewBuilder
    private var attachments: some View {
        if !message.fileAttachments.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(message.fileAttachments) { file in
                    HStack(spacing: 7) {
                        Button {
                            openFile(file.path)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(HiveTheme.amberDeep)
                                Text(file.name)
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(HiveTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            revealInFinder(file.path)
                        } label: {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中显示")
                    }
                }
            }
        }
    }

    private func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
