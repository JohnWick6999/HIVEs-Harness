import SwiftUI
import HiveHarnessCore

/// 模型管理:提供商、模型与 Agent 回退链。
struct ModelsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var draftKeys: [String: String] = [:]
    @State private var errorMessage: String?

    private var providerIDs: [String] { state.config.providers.keys.sorted() }
    private var modelIDs: [String] { state.config.models.keys.sorted() }
    private var groupID: String { state.config.defaultModelGroup }
    private var groupModels: [String] { state.config.modelGroups[groupID]?.models ?? [] }
    private var availableModelIDs: [String] { modelIDs.filter { !groupModels.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    groupSection
                    Divider()
                    providersSection
                    Divider()
                    modelsSection
                }
                .padding(16)
            }
            Divider()
            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    Text("API Key 只保存在钥匙串,不写入配置文件。模型组按顺序回退。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .onAppear(perform: loadKeys)
    }

    private func loadKeys() {
        guard draftKeys.isEmpty else { return }
        for id in providerIDs {
            draftKeys[id] = state.providerKey(id)
        }
    }

    private func save() {
        let misplaced = state.config.models.filter {
            APIKeyDetector.looksLikeAPIKey($0.value.model)
        }
        guard misplaced.isEmpty else {
            errorMessage = "模型名不能填 API Key:请把 Key 填到上方 API Key 字段,模型名填 deepseek-chat 等真实模型 id。"
            return
        }
        errorMessage = nil
        for (id, key) in draftKeys {
            state.setProviderKey(key, providerID: id)
        }
        state.saveConfig()
    }

    // MARK: - 回退链

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent 回退链").font(.headline)
                Spacer()
                Menu("加入模型") {
                    ForEach(availableModelIDs, id: \.self) { id in
                        Button(state.config.models[id]?.name ?? id) { addToGroup(id) }
                    }
                }
                .disabled(availableModelIDs.isEmpty)
            }
            Text("按顺序尝试;首个模型请求失败时自动切换下一个。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if groupModels.isEmpty {
                Text("尚未加入模型,Agent 将使用本地回退回复。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(Array(groupModels.enumerated()), id: \.element) { index, modelID in
                HStack(spacing: 8) {
                    Text("\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.config.models[modelID]?.name ?? modelID)
                            .font(.callout)
                        Text("\(state.config.models[modelID]?.provider ?? "?") / \(state.config.models[modelID]?.model ?? "?")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { move(index, -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0)
                    Button { move(index, 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == groupModels.count - 1)
                    Button(role: .destructive) { removeFromGroup(modelID) } label: {
                        Image(systemName: "minus.circle")
                    }
                }
                .padding(7)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - 提供商

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("提供商").font(.headline)
                Spacer()
                Button("添加") { addProvider() }
            }
            ForEach(providerIDs, id: \.self) { id in
                let binding = providerBinding(id)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("名称", text: binding.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Picker("", selection: binding.type) {
                            Text("OpenAI 兼容").tag("openai_compatible")
                            Text("Ollama").tag("ollama")
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        TextField("Base URL", text: binding.baseURL)
                            .textFieldStyle(.roundedBorder)
                        Toggle("启用", isOn: binding.enabled)
                            .labelsHidden()
                        Button(role: .destructive) { removeProvider(id) } label: {
                            Image(systemName: "trash")
                        }
                    }
                    HStack {
                        Text("API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("未配置", text: keyBinding(id))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - 模型

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("模型").font(.headline)
                Spacer()
                Button("添加") { addModel() }
            }
            ForEach(modelIDs, id: \.self) { id in
                let binding = modelBinding(id)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("展示名", text: binding.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField("模型名", text: modelNameBinding(id))
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: binding.provider) {
                            ForEach(providerIDs, id: \.self) { providerID in
                                Text(providerID).tag(providerID)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Toggle("启用", isOn: binding.enabled)
                        Button(role: .destructive) { removeModel(id) } label: {
                            Image(systemName: "trash")
                        }
                    }
                    if APIKeyDetector.looksLikeAPIKey(binding.wrappedValue.model) {
                        Text("这看起来像 API Key,请填到上方 API Key 字段。")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: 10) {
                        Toggle("自动上下文", isOn: autoContextBinding(id))
                            .font(.caption)
                        if let detected = ModelContextResolver.contextWindow(for: binding.wrappedValue.model) {
                            Text("检测到 \(ModelContextResolver.formatted(detected))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Stepper(
                            "窗口 \(ModelContextResolver.formatted(binding.wrappedValue.contextWindow))",
                            value: contextWindowBinding(id),
                            in: 1_024...200_000_000,
                            step: 1_048_576
                        )
                        Stepper(
                            "输出 \(binding.wrappedValue.maxOutputTokens)",
                            value: binding.maxOutputTokens,
                            in: 128...131_072,
                            step: 512
                        )
                        Toggle("工具", isOn: capabilityBinding(binding, "tools"))
                        Toggle("视觉", isOn: capabilityBinding(binding, "vision"))
                        Toggle("仅辅助", isOn: binding.auxiliaryOnly)
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Bindings

    private func modelNameBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { state.config.models[id]?.model ?? "" },
            set: { newValue in
                guard var model = state.config.models[id] else { return }
                let old = model.model
                model.model = newValue
                if model.name.isEmpty || model.name == old {
                    model.name = newValue
                }
                if model.autoContextWindow,
                   let detected = ModelContextResolver.contextWindow(for: newValue) {
                    model.contextWindow = detected
                }
                state.config.models[id] = model
            }
        )
    }

    private func autoContextBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { state.config.models[id]?.autoContextWindow ?? true },
            set: { enabled in
                guard var model = state.config.models[id] else { return }
                model.autoContextWindow = enabled
                if enabled, let detected = ModelContextResolver.contextWindow(for: model.model) {
                    model.contextWindow = detected
                }
                state.config.models[id] = model
            }
        )
    }

    private func contextWindowBinding(_ id: String) -> Binding<Int> {
        Binding(
            get: { state.config.models[id]?.contextWindow ?? 32_768 },
            set: { value in
                guard var model = state.config.models[id] else { return }
                model.contextWindow = max(1_024, value)
                // 手动调窗口意味着接管自动检测。
                model.autoContextWindow = false
                state.config.models[id] = model
            }
        )
    }

    private func providerBinding(_ id: String) -> Binding<ProviderConfig> {
        Binding(
            get: { state.config.providers[id] ?? ProviderConfig(id: id, name: id) },
            set: { state.config.providers[id] = $0 }
        )
    }

    private func modelBinding(_ id: String) -> Binding<ModelConfig> {
        Binding(
            get: {
                state.config.models[id]
                    ?? ModelConfig(id: id, provider: providerIDs.first ?? "default", model: id)
            },
            set: { state.config.models[id] = $0 }
        )
    }

    private func keyBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { draftKeys[id] ?? "" },
            set: { draftKeys[id] = $0 }
        )
    }

    private func capabilityBinding(_ binding: Binding<ModelConfig>, _ capability: String) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue.capabilities.contains(capability) },
            set: { enabled in
                var capabilities = binding.wrappedValue.capabilities
                if enabled {
                    if !capabilities.contains(capability) { capabilities.append(capability) }
                } else {
                    capabilities.removeAll { $0 == capability }
                }
                binding.wrappedValue.capabilities = capabilities
            }
        )
    }

    // MARK: - 操作

    private func addProvider() {
        var index = 1
        while state.config.providers["provider-\(index)"] != nil { index += 1 }
        let id = "provider-\(index)"
        state.config.providers[id] = ProviderConfig(id: id, name: "提供商 \(index)")
        draftKeys[id] = ""
    }

    private func removeProvider(_ id: String) {
        state.config.providers.removeValue(forKey: id)
        for modelID in state.config.models.filter({ $0.value.provider == id }).map(\.key) {
            removeModel(modelID)
        }
        draftKeys.removeValue(forKey: id)
    }

    private func addModel() {
        if providerIDs.isEmpty { addProvider() }
        var index = 1
        while state.config.models["model-\(index)"] != nil { index += 1 }
        let id = "model-\(index)"
        state.config.models[id] = ModelConfig(
            id: id,
            provider: providerIDs.first ?? "default",
            model: "gpt-4o-mini",
            name: "模型 \(index)"
        )
        addToGroup(id)
    }

    private func removeModel(_ id: String) {
        state.config.models.removeValue(forKey: id)
        removeFromGroup(id)
    }

    private func addToGroup(_ id: String) {
        guard !groupModels.contains(id) else { return }
        state.config.modelGroups[groupID]?.models.append(id)
    }

    private func removeFromGroup(_ id: String) {
        state.config.modelGroups[groupID]?.models.removeAll { $0 == id }
    }

    private func move(_ index: Int, _ offset: Int) {
        var models = groupModels
        let target = index + offset
        guard models.indices.contains(index), models.indices.contains(target) else { return }
        models.swapAt(index, target)
        state.config.modelGroups[groupID]?.models = models
    }
}
