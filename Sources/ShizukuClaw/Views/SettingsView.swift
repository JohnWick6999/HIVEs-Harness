import SwiftUI
import ShizukuCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var state = state
        TabView {
            ModelsSettingsView()
                .tabItem { Label("模型", systemImage: "cpu") }
            agentTab($state)
                .tabItem { Label("Agent", systemImage: "gearshape.2") }
            memoryTab
                .tabItem { Label("记忆", systemImage: "brain") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 760, height: 600)
        .padding(16)
    }

    // MARK: - 记忆管理

    private var memoryTab: some View {
        MemoryListView()
            .environment(state)
            .onAppear {
                state.loadMemories()
            }
    }

    // MARK: - Agent 设置

    private func agentTab(_ state: Bindable<AppState>) -> some View {
        Form {
            Picker("默认人格", selection: state.selectedPersona) {
                ForEach(state.wrappedValue.availablePersonas) { persona in
                    Text("\(persona.meta.name) (\(persona.id))")
                        .tag(persona.id)
                }
            }
            Stepper("最大工具轮数:\(state.config.agent.maxRounds)", value: state.config.agent.maxRounds, in: 1...20)
            LabeledContent("工作区") {
                Text(state.wrappedValue.workspace.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            LabeledContent("数据库") {
                Text(state.wrappedValue.store.status()["path"] ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Spacer()
                Button("保存") {
                    state.wrappedValue.saveConfig()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - 关于

    private var aboutTab: some View {
        VStack(spacing: 10) {
            Image(systemName: "cat.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("ShizukuClaw")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Alpha 0.1 · 由 Shizuku_Nya_Bot 原生移植")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("核心:ShizukuCore v\(ShizukuCore.version)\n本地智能体 · 人格 · 记忆 · MCP")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
