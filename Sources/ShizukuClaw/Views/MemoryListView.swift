import SwiftUI
import ShizukuCore

/// 长期记忆管理:查看 / 新增 / 删除(按当前人格过滤)
struct MemoryListView: View {
    @Environment(AppState.self) private var state
    @State private var newMemory = ""

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
                            Text(memory.content)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(memory.createdAt.prefix(16)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize()
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
    }

    private func add() {
        state.addMemory(newMemory)
        newMemory = ""
    }
}
