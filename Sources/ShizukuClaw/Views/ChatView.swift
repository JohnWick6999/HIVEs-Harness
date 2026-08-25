import SwiftUI
import ShizukuCore

struct ChatView: View {
    @Environment(AppState.self) private var state
    @State private var input = ""
    @State private var showSettings = false

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            header
            Divider()
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
            .onChange(of: state.messages.count) {
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
            await state.send(text)
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
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                Text(message.content.plainText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if message.role != .user {
                Spacer(minLength: 60)
            }
        }
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
