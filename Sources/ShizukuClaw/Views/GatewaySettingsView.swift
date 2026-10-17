import AppKit
import SwiftUI
import ShizukuCore

/// 本地 OpenAI 兼容网关设置。
struct GatewaySettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("本地网关") {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.gatewayRunning ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(state.gatewayRunning ? "运行中" : "未启动")
                        if let port = state.gatewayPort {
                            Text("· 端口 \(port)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Text("端口")
                    TextField("8788", value: $state.config.gateway.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .disabled(state.gatewayRunning)
                    Text("仅监听 127.0.0.1").font(.caption).foregroundStyle(.secondary)
                }
                SecureField("Bearer Token(留空表示不校验)", text: $state.config.gateway.token)
                    .textFieldStyle(.roundedBorder)
                Picker("默认人格", selection: $state.config.gateway.defaultPersona) {
                    ForEach(state.availablePersonas) { persona in
                        Text("\(persona.meta.name) (\(persona.id))").tag(persona.id)
                    }
                }
                HStack {
                    if state.gatewayRunning {
                        Button("停止网关") {
                            Task { await state.stopGateway() }
                        }
                    } else {
                        Button("启动网关") {
                            Task { await state.startGateway() }
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    Button("保存配置") { state.saveConfig() }
                    Spacer()
                }
            }

            Section("接入方式") {
                if state.gatewayRunning {
                    HStack {
                        Text(state.gatewayBaseURL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("复制 Base URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.gatewayBaseURL, forType: .string)
                        }
                    }
                }
                Text(
                    """
                    curl \(state.gatewayBaseURL)/chat/completions \\
                      -H "Content-Type: application/json" \\
                      -H "Authorization: Bearer <token>" \\
                      -d '{"model":"任意","messages":[{"role":"user","content":"你好"}]}'
                    """
                )
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

                Text("支持非流式与 SSE 流式(stream=true)。网关请求默认拒绝外部写入与执行审批;需要工具时请在主窗口操作。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = state.gatewayError {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
    }
}
