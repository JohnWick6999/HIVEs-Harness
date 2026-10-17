import AppKit
import SwiftUI
import ShizukuCore

/// MCP 服务器管理:直接编辑 `mcp/servers.json`,保存后重连并刷新工具。
struct MCPSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var text: String = ""
    @State private var status: String?
    @State private var loaded = false

    private struct ServersPayload: Codable {
        var servers: [MCPServerConfig]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MCP 服务器").font(.headline)
                Spacer()
                Button("打开目录") {
                    NSWorkspace.shared.open(state.mcpDirectory)
                }
            }
            Text("支持 stdio(command/args)与 http(url/headers)。MCP 工具只在完全控制模式可用,每次调用前会请求审批。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 320)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary, lineWidth: 1)
                )
            HStack {
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新载入") { load() }
                Button("保存并重载") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            guard !loaded else { return }
            load()
            loaded = true
        }
    }

    private func load() {
        let url = state.mcpDirectory.appendingPathComponent("servers.json")
        if let data = try? Data(contentsOf: url),
           let content = String(data: data, encoding: .utf8) {
            text = content
        } else {
            text = """
            {
              "servers": []
            }
            """
        }
        status = nil
    }

    private func save() {
        guard let data = text.data(using: .utf8) else {
            status = "编码失败"
            return
        }
        do {
            let configs: [MCPServerConfig]
            if let payload = try? JSONDecoder().decode(ServersPayload.self, from: data) {
                configs = payload.servers
            } else {
                configs = [try JSONDecoder().decode(MCPServerConfig.self, from: data)]
            }
            try MCPConfigLoader.save(configs, directory: state.mcpDirectory)
            Task {
                await state.reloadMCPConfigs()
                status = "已保存并重载 \(configs.count) 个服务器"
            }
        } catch {
            status = "保存失败: \(error.localizedDescription)"
        }
    }
}
