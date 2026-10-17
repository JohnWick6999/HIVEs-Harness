import SwiftUI
import HiveHarnessCore

/// 人格管理:内置人格不可删除,可覆盖并恢复默认;自定义人格可增删。
struct PersonaSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var editing: Persona?
    @State private var isNew = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("人格").font(.headline)
                Text("\(state.availablePersonas.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("新建人格") {
                    isNew = true
                    editing = makeNewPersona()
                }
            }
            .padding(12)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(state.availablePersonas) { persona in
                        row(persona)
                    }
                }
                .padding(12)
            }
        }
        .sheet(item: $editing) { persona in
            PersonaEditorView(persona: persona, isNew: isNew) { saved in
                state.savePersona(saved)
                editing = nil
            }
        }
    }

    private func row(_ persona: Persona) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: persona.isBuiltin ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(persona.meta.name)
                        .font(.callout.weight(.medium))
                    if persona.isBuiltin {
                        Text("内置")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.12), in: Capsule())
                        if state.personaIsCustomized(persona.id) {
                            Text("已自定义")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.orange.opacity(0.15), in: Capsule())
                        }
                    } else {
                        Text("自定义")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                }
                Text(persona.meta.description.isEmpty ? persona.character.personality : persona.meta.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("id: \(persona.id)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("编辑") {
                isNew = false
                editing = persona
            }
            if persona.isBuiltin, state.personaIsCustomized(persona.id) {
                Button("恢复默认") {
                    state.resetPersona(persona.id)
                }
            }
            if !persona.isBuiltin {
                Button("删除", role: .destructive) {
                    state.deletePersona(persona.id)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }

    private func makeNewPersona() -> Persona {
        var persona = Persona(
            meta: .init(name: "新人格", description: "自定义人格", author: "User"),
            character: .init(name: "新人格", personality: "", catchphrases: ""),
            behaviorRules: [],
            replyStyle: "清晰、自然,符合该人格的设定。",
            planStyle: "先判断用户意图,再决定回答方式。",
            systemPromptTemplate: "你是{name}。{personality}。请以该人格的身份帮助用户完成任务。"
        )
        persona.id = PersonaStore.makeCustomID()
        return persona
    }
}

private struct PersonaEditorView: View {
    let persona: Persona
    let isNew: Bool
    let onSave: (Persona) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var characterName: String
    @State private var personality: String
    @State private var catchphrases: String
    @State private var template: String
    @State private var rulesText: String
    @State private var replyStyle: String
    @State private var planStyle: String

    init(persona: Persona, isNew: Bool, onSave: @escaping (Persona) -> Void) {
        self.persona = persona
        self.isNew = isNew
        self.onSave = onSave
        _name = State(initialValue: persona.meta.name)
        _description = State(initialValue: persona.meta.description)
        _characterName = State(initialValue: persona.character.name)
        _personality = State(initialValue: persona.character.personality)
        _catchphrases = State(initialValue: persona.character.catchphrases)
        _template = State(initialValue: persona.systemPromptTemplate)
        _rulesText = State(initialValue: persona.behaviorRules.joined(separator: "\n"))
        _replyStyle = State(initialValue: persona.replyStyle)
        _planStyle = State(initialValue: persona.planStyle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isNew ? "新建人格" : "编辑人格").font(.headline)
                Spacer()
                Text(persona.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Button("关闭") { dismiss() }
            }
            Form {
                TextField("显示名称", text: $name)
                TextField("描述", text: $description)
                TextField("角色名", text: $characterName)
                TextField("性格", text: $personality)
                TextField("口头禅(可空,逗号分隔)", text: $catchphrases)
                LabeledContent("系统提示词") {
                    TextEditor(text: $template)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                }
                LabeledContent("行为规则(每行一条)") {
                    TextEditor(text: $rulesText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80)
                }
                TextField("回复风格", text: $replyStyle)
                TextField("行为规划", text: $planStyle)
            }
            HStack {
                if persona.isBuiltin {
                    Text("内置人格不可删除;保存后会覆盖默认内容,可随时恢复默认。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    var updated = persona
                    updated.meta.name = name
                    updated.meta.description = description
                    updated.character.name = characterName
                    updated.character.personality = personality
                    updated.character.catchphrases = catchphrases
                    updated.systemPromptTemplate = template
                    updated.behaviorRules = rulesText
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    updated.replyStyle = replyStyle
                    updated.planStyle = planStyle
                    onSave(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 720, height: 660)
    }
}
