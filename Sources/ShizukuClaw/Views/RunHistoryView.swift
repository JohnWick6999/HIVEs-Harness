import AppKit
import SwiftUI
import ShizukuCore

/// 运行日志:可审计的模型/工具/审批/压缩事件时间线。
struct RunHistoryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?

    private var selected: RunRecord? {
        state.runs.first { $0.id == selectedID } ?? state.runs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("运行日志").font(.title3.weight(.semibold))
                }
                Text("\(state.runs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("刷新") {
                    state.loadRuns()
                    if selectedID == nil { selectedID = state.runs.first?.id }
                }
                Button("关闭") { dismiss() }
            }
            .padding(12)
            Divider()

            if state.runs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("暂无运行记录")
                        .font(.headline)
                    Text("每次对话都会在本地记录模型、工具、审批与上下文事件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(state.runs) { run in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(statusColor(run.status))
                                        .frame(width: 7, height: 7)
                                    Text(run.startedAt, style: .time)
                                        .font(.caption.weight(.medium))
                                    Text(run.status.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(run.replyPreview.isEmpty ? "（无回复）" : run.replyPreview)
                                    .font(.caption)
                                    .lineLimit(2)
                                Text("\(run.events.count) 事件 · \(run.model)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                            .tag(run.id)
                        }
                    }
                    .frame(minWidth: 280, idealWidth: 320)

                    if let run = selected {
                        timeline(run)
                    } else {
                        Text("选择一条运行记录")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(width: 1_000, height: 650)
        .onAppear {
            state.loadRuns()
            if selectedID == nil { selectedID = state.runs.first?.id }
        }
    }

    private func timeline(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.id)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Text("\(run.persona) · \(run.model) · \(run.startedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("复制 JSON") { copyJSON(run) }
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(run.events) { event in
                        eventRow(event)
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 520)
    }

    private func eventRow(_ event: RunEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(event.kind))
                .font(.caption)
                .foregroundStyle(color(event.kind))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(.caption.weight(.semibold))
                    if let duration = event.durationMs {
                        Text("\(duration)ms")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let ok = event.ok, !ok {
                        Text("失败")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text(event.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(event.kind == .tool ? 10 : 24)
                        .foregroundStyle(.secondary)
                }
                if !event.metadata.isEmpty {
                    Text(event.metadata.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func statusColor(_ status: RunStatus) -> Color {
        switch status {
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    private func icon(_ kind: RunEventKind) -> String {
        switch kind {
        case .started: return "play.circle"
        case .model: return "cpu"
        case .tool: return "wrench.and.screwdriver"
        case .approval: return "hand.raised"
        case .plan: return "checklist"
        case .context: return "gauge"
        case .finished: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    private func color(_ kind: RunEventKind) -> Color {
        switch kind {
        case .started, .finished: return .green
        case .model: return .blue
        case .tool: return .accentColor
        case .approval: return .orange
        case .plan: return .purple
        case .context: return .teal
        case .error: return .red
        }
    }

    private func copyJSON(_ run: RunRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(run),
              let text = String(data: data, encoding: .utf8)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
