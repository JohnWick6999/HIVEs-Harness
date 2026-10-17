import AppKit
import SwiftUI
import HiveHarnessCore

/// 工作台:文件浏览、Git 变更、Shell(仅完全控制模式 + 确认)。
struct WorkbenchView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var tab = 0
    @State private var currentPath = "."
    @State private var entries: [WorkspaceEntry] = []
    @State private var selectedFile: WorkspaceEntry?
    @State private var preview = ""
    @State private var error: String?

    @State private var changes = "点击“刷新”查看工作区 Git 变更。"
    @State private var changesLoading = false

    @State private var shellCommand = ""
    @State private var shellOutput = ""
    @State private var shellRunning = false
    @State private var pendingShell = ""
    @State private var confirmShell = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case 0: filesTab
            case 1: changesTab
            default: shellTab
            }
        }
        .frame(width: 920, height: 640)
        .onAppear {
            loadFiles()
        }
        .onChange(of: tab) { _, value in
            if value == 1 { loadChanges() }
        }
        .confirmationDialog(
            "执行 Shell 命令?",
            isPresented: $confirmShell,
            presenting: pendingShell
        ) { command in
            Button("执行", role: .destructive) { runShell(command) }
            Button("取消", role: .cancel) {}
        } message: { command in
            Text(command)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                Text("工作台").font(.title3.weight(.semibold))
            }
            Picker("", selection: $tab) {
                Text("文件").tag(0)
                Text("变更").tag(1)
                Text("Shell").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Spacer()
            if tab == 0 {
                Text(currentPath == "." ? "工作区根目录" : currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if tab == 1 {
                Button("刷新") { loadChanges() }
            }
            Button("关闭") { dismiss() }
        }
        .padding(12)
    }

    // MARK: - 文件

    private var filesTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("上一级") {
                    currentPath = parentPath
                    loadFiles()
                }
                .disabled(currentPath == ".")
                Button("工作区根目录") {
                    currentPath = "."
                    loadFiles()
                }
                Spacer()
                Button("在 Finder 中显示") {
                    openInFinder()
                }
                .disabled(selectedFile == nil)
                Button("刷新") { loadFiles() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }

            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in
                            fileRow(entry)
                        }
                    }
                    .padding(6)
                }
                .frame(minWidth: 260, idealWidth: 300)

                ScrollView {
                    Text(preview)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minWidth: 420)
            }
        }
    }

    private func fileRow(_ entry: WorkspaceEntry) -> some View {
        Button {
            if entry.isDirectory {
                currentPath = entry.path
                loadFiles()
            } else {
                selectedFile = entry
                loadPreview(entry)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                    .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                Text(entry.name)
                    .lineLimit(1)
                Spacer()
                if !entry.isDirectory {
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(entry.size),
                        countStyle: .file
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                selectedFile?.id == entry.id ? Color.blue.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var parentPath: String {
        let parts = currentPath.split(separator: "/")
        return parts.count <= 1 ? "." : parts.dropLast().joined(separator: "/")
    }

    private func loadFiles() {
        do {
            entries = try state.workspaceService.list(path: currentPath)
            error = nil
            selectedFile = nil
            preview = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadPreview(_ entry: WorkspaceEntry) {
        do {
            preview = try state.workspaceService.read(path: entry.path)
        } catch {
            preview = error.localizedDescription
        }
    }

    private func openInFinder() {
        let target = selectedFile.map {
            state.workspace.appendingPathComponent($0.path)
        } ?? state.workspace
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - 变更

    private var changesTab: some View {
        VStack(spacing: 0) {
            HStack {
                Text("git status --short + git diff")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("初始化 Git") {
                    let service = state.workspaceService
                    Task {
                        _ = await Task.detached { try? service.runShell("git init -q") }.value
                        loadChanges()
                    }
                }
                Button("刷新") { loadChanges() }
            }
            .padding(10)
            Divider()
            if changesLoading {
                ProgressView().padding(30)
            } else {
                ScrollView {
                    Text(changes)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
        }
    }

    private func loadChanges() {
        changesLoading = true
        let service = state.workspaceService
        Task {
            let text = await Task.detached {
                let status = service.gitStatus()
                let diff = service.gitDiff()
                return [status, diff]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n\n")
            }.value
            changes = text.isEmpty ? "（没有变更,或工作区不是 Git 仓库）" : text
            changesLoading = false
        }
    }

    // MARK: - Shell

    private var shellTab: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                TextField("输入命令(在完全控制模式下会先确认)", text: $shellCommand)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { requestShell() }
                Button(shellRunning ? "运行中…" : "运行") { requestShell() }
                    .disabled(shellRunning || shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("清空") { shellOutput = "" }
            }
            .padding(10)

            if state.config.agent.workMode != .full {
                Text("Shell 仅在完全控制模式下可用。请在顶栏切换到完全控制模式(需要系统身份验证)。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()
            ScrollView {
                Text(shellOutput.isEmpty ? "输出会显示在这里。" : shellOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(shellOutput.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
    }

    private func requestShell() {
        let command = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard state.config.agent.workMode == .full else {
            shellOutput = "需要先切换到完全控制模式。"
            return
        }
        pendingShell = command
        confirmShell = true
    }

    private func runShell(_ command: String) {
        shellRunning = true
        shellOutput = "$ \(command)\n"
        let service = state.workspaceService
        Task {
            let result = await Task.detached { try? service.runShell(command) }.value
            if let result {
                var text = "$ \(command)\nexit \(result.exitCode)"
                if result.timedOut { text += " (超时)" }
                text += "\n"
                if !result.stdout.isEmpty { text += result.stdout }
                if !result.stderr.isEmpty { text += "\n[stderr]\n" + result.stderr }
                shellOutput = text
            } else {
                shellOutput += "\n执行失败"
            }
            shellRunning = false
        }
    }
}
