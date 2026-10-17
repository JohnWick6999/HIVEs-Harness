import SwiftUI
import ShizukuCore

/// 长期记忆管理:查看 / 新增 / 删除(按当前人格过滤)
struct MemoryListView: View {
    @Environment(AppState.self) private var state
    @State private var newMemory = ""
    @State private var editing: MemoryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("新增长期记忆…(Enter 添加)", text: $newMemory)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("添加") { add() }
                    .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if state.memories.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("暂无长期记忆")
                        .font(.headline)
                    Text("聊天时超过 12 字的消息会自动记录,也可以手动添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(state.memories) { memory in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(memory.content)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 8) {
                                    Text(sourceLabel(memory.sourceKind))
                                    if let thread = memory.sourceThread, !thread.isEmpty {
                                        Text("会话 \(thread.prefix(12))")
                                    }
                                    Text("置信 \(Int(memory.confidence * 100))%")
                                    if memory.useCount > 0 {
                                        Text("检索 \(memory.useCount) 次")
                                    }
                                    if let last = memory.lastUsedAt, !last.isEmpty {
                                        Text("最近 \(last.prefix(16))")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            Text(String(memory.createdAt.prefix(16)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                            Button {
                                editing = memory
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("编辑这条记忆")
                            Button {
                                state.deleteMemory(memory)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("删除这条记忆")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding()
        .sheet(item: $editing) { memory in
            MemoryEditView(memory: memory) { content, confidence in
                state.updateMemory(memory, content: content, confidence: confidence)
            }
        }
    }

    private func add() {
        state.addMemory(newMemory)
        newMemory = ""
    }

    private func sourceLabel(_ kind: String) -> String {
        switch kind {
        case "auto": return "自动记录"
        case "tool": return "工具写入"
        default: return "手动添加"
        }
    }
}

private struct MemoryEditView: View {
    let memory: MemoryItem
    let onSave: (String, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var confidence: Double

    init(memory: MemoryItem, onSave: @escaping (String, Double) -> Void) {
        self.memory = memory
        self.onSave = onSave
        _content = State(initialValue: memory.content)
        _confidence = State(initialValue: memory.confidence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("编辑记忆").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }
            TextEditor(text: $content)
                .font(.body)
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary, lineWidth: 1)
                )
            HStack(spacing: 10) {
                Text("置信度").font(.caption)
                Slider(value: $confidence, in: 0...1, step: 0.05)
                Text("\(Int(confidence * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            if let source = memory.sourceKind as String? {
                Text("来源: \(sourceLabel(source))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(content, confidence)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }

    private func sourceLabel(_ kind: String) -> String {
        switch kind {
        case "auto": return "自动记录"
        case "tool": return "工具写入"
        default: return "手动添加"
        }
    }
}
