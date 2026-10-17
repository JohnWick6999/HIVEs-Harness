import AppKit
import SwiftUI
import ShizukuCore

/// 技能管理:内置技能 + 用户 SKILL.md,可启停、查看指令、打开目录。
struct SkillsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var selected: Skill?
    @State private var selectedProposal: SkillProposal?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("技能").font(.headline)
                Text("\(state.skills.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "自动提炼",
                    isOn: Binding(
                        get: { state.config.agent.autoEvolveSkills },
                        set: {
                            state.config.agent.autoEvolveSkills = $0
                            state.saveConfig()
                        }
                    )
                )
                .toggleStyle(.switch)
                .font(.caption)
                .help("成功且有多次工具调用的任务会在后台反思生成技能提案,批准后才启用")
                Spacer()
                Button("打开目录") {
                    NSWorkspace.shared.open(state.skillsDirectory)
                }
                Menu("维护") {
                    Button("归档 30 天未用技能") {
                        state.archiveStaleSkills()
                    }
                    Button("重新载入") {
                        state.reloadSkills()
                    }
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !state.skillProposals.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text("待审技能提案")
                                    .font(.caption.weight(.semibold))
                                Text("\(state.skillProposals.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(state.skillProposals) { proposal in
                                proposalRow(proposal)
                            }
                        }
                        .padding(.bottom, 6)
                        Divider()
                    }
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
        .sheet(item: $selectedProposal) { proposal in
            SkillProposalDetailView(proposal: proposal)
                .environment(state)
        }
    }

    private func proposalRow(_ proposal: SkillProposal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.name)
                    .font(.callout.weight(.medium))
                Text(proposal.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text((proposal.action ?? "create") == "patch" ? "更新现有技能" : "新建技能")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: Capsule())
                    if let target = proposal.targetID {
                        Text(target).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !proposal.reason.isEmpty {
                    Text("理由: \(proposal.reason)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                if let warnings = proposal.warnings, !warnings.isEmpty {
                    Text(warnings.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("查看") { selectedProposal = proposal }
            Button("批准") { state.approveSkillProposal(proposal) }
            Button("拒绝") { state.rejectSkillProposal(proposal) }
        }
        .padding(8)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
                    HStack(spacing: 6) {
                        if skill.useCount > 0 {
                            Text("使用 \(skill.useCount) 次")
                        }
                        if skill.isStale {
                            Text("14 天未用").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

private struct SkillProposalDetailView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let proposal: SkillProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.name)
                        .font(.title3.weight(.semibold))
                    Text((proposal.action ?? "create") == "patch"
                         ? "更新现有技能 \(proposal.targetID ?? "")"
                         : "新建技能")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text(proposal.description)
                .font(.callout)
            if !proposal.reason.isEmpty {
                Text("理由: \(proposal.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let warnings = proposal.warnings, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if (proposal.action ?? "create") == "patch",
               let target = proposal.targetID,
               let old = state.skills.first(where: { $0.id == target }) {
                DisclosureGroup("将覆盖的现有技能: \(old.name)") {
                    ScrollView {
                        Text(old.body)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.caption)
            }
            Divider()
            Text("提案正文").font(.caption.weight(.semibold))
            ScrollView {
                Text(proposal.body)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("拒绝") {
                    state.rejectSkillProposal(proposal)
                    dismiss()
                }
                Button("批准并启用") {
                    state.approveSkillProposal(proposal)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 700, height: 560)
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
