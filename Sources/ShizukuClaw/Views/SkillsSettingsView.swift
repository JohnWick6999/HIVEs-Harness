import AppKit
import SwiftUI
import ShizukuCore

/// 技能管理:内置技能 + 用户 SKILL.md,可启停、查看指令、打开目录。
struct SkillsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var selected: Skill?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("技能").font(.headline)
                Text("\(state.skills.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("打开目录") {
                    NSWorkspace.shared.open(state.skillsDirectory)
                }
                Button("重新载入") {
                    state.reloadSkills()
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if state.skills.isEmpty {
                        Text("暂无技能。可把含 SKILL.md 的目录放入技能目录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(state.skills) { skill in
                        skillRow(skill)
                    }
                }
                .padding(12)
            }
        }
        .sheet(item: $selected) { skill in
            SkillDetailView(skill: skill)
        }
    }

    private func skillRow(_ skill: Skill) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                selected = skill
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.callout.weight(.medium))
                        if skill.isBuiltin {
                            Text("内置")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.blue.opacity(0.12), in: Capsule())
                        }
                        if skill.hasHandler {
                            Text("含 handler")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.orange.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(skill.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !skill.tags.isEmpty {
                        Text(skill.tags.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { skill.enabled },
                    set: { state.setSkillEnabled(skill.id, enabled: $0) }
                )
            )
            .labelsHidden()

            if !skill.isBuiltin {
                Button(role: .destructive) {
                    try? state.skillStore.remove(id: skill.id)
                    state.reloadSkills()
                } label: {
                    Image(systemName: "trash")
                }
                .help("删除用户技能")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct SkillDetailView: View {
    let skill: Skill
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("\(skill.id) · v\(skill.version)\(skill.author.isEmpty ? "" : " · \(skill.author)")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text(skill.description)
                .font(.callout)
            Divider()
            ScrollView {
                Text(skill.body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(width: 640, height: 500)
    }
}
