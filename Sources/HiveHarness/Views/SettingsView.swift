import SwiftUI
import HiveHarnessCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var section: Section = .models

    enum Section: String, CaseIterable, Identifiable {
        case models, agent, personas, mcp, skills, gateway, memory, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .models: return "模型"
            case .agent: return "Agent"
            case .personas: return "人格"
            case .mcp: return "MCP"
            case .skills: return "技能"
            case .gateway: return "网关"
            case .memory: return "记忆"
            case .about: return "关于"
            }
        }

        var icon: String {
            switch self {
            case .models: return "cpu"
            case .agent: return "gearshape.2"
            case .personas: return "person.2"
            case .mcp: return "server.rack"
            case .skills: return "wand.and.stars"
            case .gateway: return "network"
            case .memory: return "brain"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        ZStack {
            HiveBackground()
            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(HiveTheme.hairline)
                    .frame(width: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(18)
            }
        }
        .frame(width: 940, height: 700)
        .tint(HiveTheme.amberDeep)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                HiveMark(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("HIVE's Harness")
                        .font(.system(.callout, design: .rounded).weight(.bold))
                    Text("设置")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)

            ForEach(Section.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        section = item
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.icon)
                            .frame(width: 17)
                        Text(item.title)
                            .font(.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        section == item ? HiveTheme.amber.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .foregroundStyle(section == item ? HiveTheme.amberDeep : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("本地优先 · 数据留在本机")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
        }
        .padding(14)
        .frame(width: 196)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .models:
            ModelsSettingsView()
        case .agent:
            agentSettings
        case .personas:
            PersonaSettingsView()
        case .mcp:
            MCPSettingsView()
        case .skills:
            SkillsSettingsView()
        case .gateway:
            GatewaySettingsView()
        case .memory:
            memorySettings
        case .about:
            aboutSettings
        }
    }

    // MARK: - 记忆

    private var memorySettings: some View {
        MemoryListView()
            .environment(state)
            .onAppear {
                state.loadMemories()
            }
    }

    // MARK: - Agent

    private var agentSettings: some View {
        AgentSettingsView(state: state)
    }

    // MARK: - 关于

    private var aboutSettings: some View {
        VStack(spacing: 12) {
            HiveMark(size: 62)
            Text("HIVE's Harness")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Alpha 0.1 · 本地优先的 macOS 智能体")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("核心:HiveHarnessCore v\(HiveHarnessCore.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("人格 · 记忆 · MCP · Skills · 插件市场 · 本地网关")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("默认行为") {
                Picker("默认人格", selection: $state.selectedPersona) {
                    ForEach(state.availablePersonas) { persona in
                        Text("\(persona.meta.name) (\(persona.id))")
                            .tag(persona.id)
                    }
                }
                Stepper(
                    "最大工具轮数:\(state.config.agent.maxRounds)",
                    value: $state.config.agent.maxRounds,
                    in: 1...20
                )
                Toggle("成功后自动提炼技能提案", isOn: $state.config.agent.autoEvolveSkills)
            }

            Section("存储") {
                LabeledContent("工作区") {
                    Text(state.workspace.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                LabeledContent("数据库") {
                    Text(state.store.status()["path"] ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("保存") {
                        state.saveConfig()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
