import SwiftUI
import HiveHarnessCore

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var section: Section = .models
    @AppStorage(HiveTheme.appearanceKey) private var appearance = HiveAppearance.system.rawValue
    @AppStorage(HiveTheme.glassIntensityKey) private var glassIntensity = HiveTheme.defaultGlassIntensity
    @AppStorage(HiveTheme.sidebarWidthKey) private var sidebarWidth = HiveTheme.defaultSidebarWidth
    @AppStorage(HiveTheme.showUsageBarKey) private var showUsageBar = true

    enum Section: String, CaseIterable, Identifiable {
        case appearance, artifacts, models, agent, personas, mcp, skills, gateway, memory, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance: return "外观"
            case .artifacts: return "产物"
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
            case .appearance: return "paintpalette"
            case .artifacts: return "doc.richtext"
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
        .preferredColorScheme(HiveAppearance(rawValue: appearance)?.colorScheme)
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
        case .appearance:
            appearanceSettings
        case .artifacts:
            artifactSettings
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

    // MARK: - 外观

    private var appearanceSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("外观")
                    .font(.title2.weight(.bold))

                VStack(alignment: .leading, spacing: 8) {
                    Text("主题")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("主题", selection: $appearance) {
                        ForEach(HiveAppearance.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .hiveCard(padding: 14)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("液态玻璃强度")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((glassIntensity * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(HiveTheme.amberDeep)
                    }
                    Slider(value: $glassIntensity, in: 0...1)
                        .tint(HiveTheme.amberDeep)
                    HStack {
                        Text("轻")
                        Spacer()
                        Text("Apple 桌面卡片")
                        Spacer()
                        Text("强")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    Text("0.55 接近 Apple 桌面卡片强度;调高会增加高光与折射,不影响正文对比度。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .hiveCard(padding: 14)

                ZStack {
                    HiveBackground()
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            HiveMark(size: 26)
                            Text("实时玻璃预览")
                                .font(.headline)
                            Spacer()
                        }
                        Text("这是一段正文。调节强度时,卡片的高光、边缘折射和阴影会实时变化。")
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Text("正文保持不透明,玻璃只作用于背景层。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .hiveCard(padding: 18, corner: 18)
                    .padding(18)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(HiveTheme.hairline, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("侧栏宽度")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(sidebarWidth)) pt")
                            .font(.caption.monospacedDigit())
                    }
                    Slider(value: $sidebarWidth, in: 200...360)
                        .tint(HiveTheme.amberDeep)
                    Text("也可以直接拖动侧栏右边缘调整,宽度会自动保存。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .hiveCard(padding: 14)

                Toggle(isOn: $showUsageBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示底部 Token 用量栏")
                            .font(.callout)
                        Text("关闭后隐藏底部的 token、缓存命中、轮数与工具调用统计。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .hiveCard(padding: 14)

                Button("恢复默认外观") {
                    appearance = HiveAppearance.system.rawValue
                    glassIntensity = HiveTheme.defaultGlassIntensity
                    sidebarWidth = HiveTheme.defaultSidebarWidth
                    showUsageBar = true
                }
                .buttonStyle(.bordered)
            }
            .padding(.trailing, 8)
        }
    }

    // MARK: - 产物打开方式

    private var artifactSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("产物打开方式")
                        .font(.title2.weight(.bold))
                    Text("Agent 交付文件后,点击消息下方的玻璃卡片会按这里的设置打开。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    ForEach(Array(ArtifactKind.allCases.enumerated()), id: \.element.id) { index, kind in
                        HStack(spacing: 10) {
                            Image(systemName: kind.icon)
                                .frame(width: 20)
                                .foregroundStyle(HiveTheme.amberDeep)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.title)
                                    .font(.callout)
                                Text(defaultHint(kind))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("", selection: artifactModeBinding(kind)) {
                                ForEach(ArtifactOpenMode.allCases) { mode in
                                    Label(mode.title, systemImage: mode.icon).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        if index < ArtifactKind.allCases.count - 1 {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .hiveCard(padding: 4, corner: 12)

                HStack {
                    Text("网页使用内置 WKWebView;PDF/Office/图片使用 QuickLook;文本和代码使用内置文本查看器。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("全部恢复右侧边栏") {
                        for kind in ArtifactKind.allCases {
                            ArtifactPreferences.set(.sidebar, for: kind)
                            artifactModes[kind] = .sidebar
                        }
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    @State private var artifactModes: [ArtifactKind: ArtifactOpenMode] = [:]

    private func artifactModeBinding(_ kind: ArtifactKind) -> Binding<ArtifactOpenMode> {
        Binding(
            get: { artifactModes[kind] ?? ArtifactPreferences.mode(for: kind) },
            set: { mode in
                artifactModes[kind] = mode
                ArtifactPreferences.set(mode, for: kind)
            }
        )
    }

    private func defaultHint(_ kind: ArtifactKind) -> String {
        switch kind {
        case .html: return "内置浏览器渲染 HTML"
        case .pdf, .office: return "内置 QuickLook 文档查看器"
        case .image: return "内置图片预览"
        case .text, .code: return "内置文本 / 代码查看器"
        case .other: return "QuickLook 或系统默认"
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
                    in: 1...40
                )
                Toggle("成功后自动提炼技能提案", isOn: $state.config.agent.autoEvolveSkills)
                Picker("主动提问", selection: $state.config.agent.clarificationMode) {
                    ForEach(ClarificationMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(state.config.agent.clarificationMode.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
