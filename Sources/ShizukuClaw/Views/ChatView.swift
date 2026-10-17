import SwiftUI
import ShizukuCore

struct ChatView: View {
    @Environment(AppState.self) private var state
    @State private var input = ""
    @State private var showSettings = false
    @State private var planExpanded = true
    @State private var showContext = false

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            header
            Divider()
            if !state.taskPlan.items.isEmpty {
                planPanel
                Divider()
            }
            messageList
            Divider()
            inputBar
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(state)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
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
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var personaName: String {
        state.availablePersonas.first { $0.id == state.selectedPersona }?.meta.name
            ?? state.selectedPersona
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
                                .trim(from: 0, to: min(1, max(0, state.contextState.usagePercent / 100)))
                                .stroke(usageColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 16, height: 16)
                        Text("\(Int(state.contextState.usagePercent.rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("上下文用量")
                .popover(isPresented: $showContext, arrowEdge: .bottom) {
                    contextPopover
                }
            }
        }
    }

    private var usageColor: Color {
        let usage = state.contextState.usagePercent
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
                GridRow {
                    Text("本轮估算")
                    Text("\(state.contextState.estimatedTokens) tokens")
                }
                GridRow {
                    Text("摘要覆盖")
                    Text("\(state.contextState.coveredCount) 条消息")
                }
            }
            .font(.caption)

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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
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
                    }
                    ForEach(state.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if !state.lastToolTrace.isEmpty {
                        toolTraceRow
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(14)
            }
            .onChange(of: state.messages.last?.content.plainText) {
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("和 \(personaName) 打个招呼吧")
                .font(.headline)
            Text("没有配置 API Key 时,Shizuku 会以本地回退模式回复")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var toolTraceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
            Text("调用了 \(state.lastToolTrace.count) 个工具:\(state.lastToolTrace.map(\.tool).joined(separator: ", "))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("输入消息…(Enter 发送,Shift+Enter 换行)", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit {
                    send()
                }
                .disabled(state.isBusy)

            if state.isBusy {
                Button(role: .destructive) {
                    // Alpha 阶段无取消机制,仅提示
                } label: {
                    Image(systemName: "stop.circle")
                }
                .disabled(true)
            }

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
            }
            .disabled(state.isBusy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
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

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 60)
            }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                if !message.content.plainText.isEmpty {
                    Text(message.content.plainText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
                }
                // 工具产出文件:可点击卡片
                if !message.fileAttachments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.fileAttachments) { file in
                            HStack(spacing: 8) {
                                Button {
                                    openFile(file.path)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text")
                                        Text(file.name)
                                            .lineLimit(1)
                                        Image(systemName: "arrow.up.forward.app")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if message.role != .user {
                Spacer(minLength: 60)
            }
        }
    }

    private func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private var backgroundColor: Color {
        message.role == .user ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12)
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "你"
        case .assistant: return personaName
        case .system: return "系统"
        case .tool: return "工具"
        }
    }

    private var personaName: String {
        "Shizuku"
    }
}
