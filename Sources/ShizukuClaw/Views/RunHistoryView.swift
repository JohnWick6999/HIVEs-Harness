import AppKit
import SwiftUI
import ShizukuCore

/// 运行日志:可审计的模型/工具/审批/压缩事件时间线。
struct RunHistoryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var replay: RunReplay?
    @State private var isPlaying = false
    @State private var playTask: Task<Void, Never>?

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
                    if let first = state.runs.first {
                        selectedID = first.id
                        replay = RunReplay(run: first, cursor: first.events.count)
                    }
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
            if let first = state.runs.first {
                selectedID = first.id
                replay = RunReplay(run: first, cursor: first.events.count)
            }
        }
        .onChange(of: selectedID) { _, _ in
            stop()
            if let run = selected {
                replay = RunReplay(run: run, cursor: run.events.count)
            } else {
                replay = nil
            }
        }
        .onDisappear {
            stop()
        }
    }

    private func replay(for run: RunRecord) -> RunReplay {
        if let replay, replay.runID == run.id { return replay }
        return RunReplay(run: run, cursor: run.events.count)
    }

    private func resetReplay() {
        guard var current = replay else { return }
        current.reset()
        replay = current
        stop()
    }

    private func stepForward() {
        guard var current = replay else { return }
        _ = current.step()
        replay = current
        if current.isFinished { stop() }
    }

    private func stepBack() {
        guard var current = replay else { return }
        current.jump(to: current.cursor - 1)
        replay = current
        stop()
    }

    private func jumpToEnd() {
        guard var current = replay else { return }
        current.toEnd()
        replay = current
        stop()
    }

    private func togglePlay() {
        if isPlaying {
            stop()
            return
        }
        guard var current = replay else { return }
        if current.isFinished {
            current.reset()
            replay = current
        }
        isPlaying = true
        playTask?.cancel()
        playTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, isPlaying else { break }
                stepForward()
            }
            if isPlaying { isPlaying = false }
        }
    }

    private func stop() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    private func timeline(_ run: RunRecord) -> some View {
        let active = replay(for: run)
        return VStack(alignment: .leading, spacing: 0) {
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

            HStack(spacing: 8) {
                Button { resetReplay() } label: { Image(systemName: "backward.end") }
                    .help("回到开头")
                Button { stepBack() } label: { Image(systemName: "backward.frame") }
                    .help("上一步")
                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .help(isPlaying ? "暂停" : "播放")
                Button { stepForward() } label: { Image(systemName: "forward.frame") }
                    .help("下一步")
                Button { jumpToEnd() } label: { Image(systemName: "forward.end") }
                    .help("跳到结尾")
                Text("\(active.cursor)/\(active.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("事件回放(不执行副作用)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(active.visibleEvents) { event in
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
