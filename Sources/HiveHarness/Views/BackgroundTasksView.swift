import SwiftUI
import HiveHarnessCore

/// 后台任务面板:查看状态、结果与取消。
struct AgentBackgroundTasksView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HiveMark(size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("后台任务").font(.headline)
                    Text("只读子代理在后台运行,不阻塞对话")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(state.backgroundTasks.count) 个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("关闭") { dismiss() }
            }
            .padding(14)
            Rectangle().fill(HiveTheme.hairline).frame(height: 1)

            if state.backgroundTasks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("暂无后台任务")
                        .font(.headline)
                    Text("让 Agent 启动一个长调研,它会出现在这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(state.backgroundTasks) { task in
                            taskRow(task)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 760, height: 600)
        .background(HiveBackground())
        .tint(HiveTheme.amberDeep)
    }

    private func taskRow(_ task: AgentBackgroundTask) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon(task.status))
                    .foregroundStyle(statusColor(task.status))
                Text(task.title)
                    .font(.callout.weight(.medium))
                Text(task.status.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(statusColor(task.status).opacity(0.12), in: Capsule())
                    .foregroundStyle(statusColor(task.status))
                Spacer()
                Text(task.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if task.status == .running {
                    Button("取消") { state.cancelAgentBackgroundTask(task.id) }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
            }
            Text(task.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(expanded == task.id ? nil : 2)
            if let result = task.result, !result.isEmpty {
                Text(result)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(expanded == task.id ? nil : 4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HiveTheme.card, in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = task.error, !error.isEmpty, task.result == nil {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            HStack {
                if task.result != nil || expanded == task.id {
                    Button(expanded == task.id ? "收起" : "展开") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expanded = expanded == task.id ? nil : task.id
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(HiveTheme.amberDeep)
                }
                Spacer()
                if let finished = task.finishedAt {
                    Text("完成于 \(finished.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HiveTheme.hairline, lineWidth: 1)
        )
    }

    private func statusIcon(_ status: AgentBackgroundTaskStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private func statusColor(_ status: AgentBackgroundTaskStatus) -> Color {
        switch status {
        case .queued: return .secondary
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
