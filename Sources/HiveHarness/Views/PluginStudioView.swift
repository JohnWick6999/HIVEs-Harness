import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HiveHarnessCore

/// 插件工坊:创建、编辑、校验、安装与导出声明式插件。
struct PluginStudioView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: String?
    @State private var selectedFile: String?
    @State private var editorText = ""
    @State private var report: PluginValidationReport?
    @State private var showNew = false
    @State private var newName = ""
    @State private var newTemplate: PluginTemplate = .skillPack
    @State private var error: String?
    @State private var message: String?

    private var project: PluginProject? {
        state.pluginProjects.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(HiveTheme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(HiveTheme.hairline).frame(width: 1)
                if let project {
                    editor(project)
                } else {
                    emptyState
                }
            }
        }
        .frame(width: 1_020, height: 700)
        .background(HiveBackground())
        .tint(HiveTheme.amberDeep)
        .task {
            state.reloadPluginProjects()
            if selectedID == nil { selectedID = state.pluginProjects.first?.id }
            loadSelectedFile()
        }
        .onChange(of: selectedID) { _, _ in
            report = nil
            selectedFile = project?.files.first
            loadSelectedFile()
        }
        .onChange(of: selectedFile) { _, _ in
            loadSelectedFile()
        }
        .sheet(isPresented: $showNew) {
            newPluginSheet
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            HiveMark(size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("插件工坊").font(.headline)
                Text("声明式 · 只安装 SKILL.md 与 MCP,不执行插件代码")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(PluginTemplate.allCases) { template in
                    Button {
                        newTemplate = template
                        newName = ""
                        showNew = true
                    } label: {
                        VStack(alignment: .leading) {
                            Text(template.title)
                            Text(template.detail).font(.caption)
                        }
                    }
                }
            } label: {
                Label("新建插件", systemImage: "plus")
            }
            Button {
                importBundle()
            } label: {
                Label("导入", systemImage: "square.and.arrow.down")
            }
            Button("市场索引") { exportMarketplace() }
            Button("关闭") { dismiss() }
        }
        .padding(12)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("我的插件").font(.caption.weight(.semibold))
                Spacer()
                Text("\(state.pluginProjects.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            List(selection: $selectedID) {
                ForEach(state.pluginProjects) { project in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.manifest.name)
                            .font(.callout.weight(.medium))
                        Text("v\(project.manifest.version) · \(project.manifest.skills.count) skills · \(project.manifest.mcpServers.count) MCP")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(project.id)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 230)
        .background(.ultraThinMaterial)
    }

    private func editor(_ project: PluginProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.manifest.name)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                    Text("\(project.manifest.id) · v\(project.manifest.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存") { save(project) }
                Button("校验") { validate(project) }
                Button("安装") { install(project) }
                Button("导出") { exportBundle(project) }
            }

            Picker("文件", selection: $selectedFile) {
                ForEach(project.files, id: \.self) { file in
                    Text(file).tag(Optional(file))
                }
            }
            .frame(width: 380)

            TextEditor(text: $editorText)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(HiveTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(HiveTheme.hairline, lineWidth: 1)
                )
                .frame(maxHeight: .infinity)

            if let report {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.issues.prefix(8)) { issue in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: issueIcon(issue.severity))
                                .foregroundStyle(issueColor(issue.severity))
                            Text(issue.path.isEmpty ? issue.message : "\(issue.path): \(issue.message)")
                                .font(.caption2)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HiveTheme.card, in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                if let error {
                    Text(error).font(.caption2).foregroundStyle(.red)
                } else if let message {
                    Text(message).font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                Text(project.root.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            HiveMark(size: 56)
            Text("创建你的第一个插件")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text("用 SKILL.md 描述工作流,或用 MCP 连接外部工具。\n工坊只生成声明式文件,不执行代码。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("新建插件") {
                newTemplate = .skillPack
                showNew = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newPluginSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建插件").font(.headline)
            TextField("插件名称", text: $newName)
                .textFieldStyle(.roundedBorder)
            Picker("模板", selection: $newTemplate) {
                ForEach(PluginTemplate.allCases) { template in
                    Text(template.title).tag(template)
                }
            }
            Text(newTemplate.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { showNew = false }
                Button("创建") {
                    do {
                        let created = try state.createPlugin(
                            name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
                            template: newTemplate
                        )
                        selectedID = created.id
                        selectedFile = created.files.first
                        showNew = false
                        message = "已创建 \(created.manifest.name)"
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func loadSelectedFile() {
        guard let project, let file = selectedFile else {
            editorText = ""
            return
        }
        do {
            editorText = try state.pluginStudio.readFile(project: project, path: file)
        } catch {
            editorText = ""
            self.error = error.localizedDescription
        }
    }

    private func save(_ project: PluginProject) {
        guard let file = selectedFile else { return }
        do {
            let refreshed = try state.savePluginFile(
                project,
                path: file,
                content: editorText
            )
            if let refreshed {
                selectedID = refreshed.id
                selectedFile = file
            }
            report = state.validatePlugin(refreshed ?? project)
            message = "已保存 \(file)"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func validate(_ project: PluginProject) {
        report = state.validatePlugin(project)
        message = report?.canInstall == true ? "校验通过" : "校验发现错误"
        error = nil
    }

    private func install(_ project: PluginProject) {
        do {
            let skills = try state.installPlugin(project)
            message = "已安装 \(skills.count) 个技能;MCP 已写入并默认停用"
            report = state.validatePlugin(project)
            error = nil
            state.reloadPluginProjects()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func exportBundle(_ project: PluginProject) {
        do {
            let data = try state.exportPlugin(project)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(project.manifest.id).hiveplugin.json"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
                message = "已导出 \(url.lastPathComponent)"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func exportMarketplace() {
        do {
            let data = try state.exportPluginMarketplaceIndex()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "marketplace.json"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
                message = "已导出市场索引;连同插件目录一起托管即可"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importBundle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let project = try state.importPlugin(data: data)
            selectedID = project.id
            selectedFile = project.files.first
            message = "已导入 \(project.manifest.name)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func issueIcon(_ severity: PluginIssueSeverity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func issueColor(_ severity: PluginIssueSeverity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
