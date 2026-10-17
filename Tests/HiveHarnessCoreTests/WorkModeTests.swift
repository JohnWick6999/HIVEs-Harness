import Foundation
@testable import HiveHarnessCore
import Testing

/// 记录审批请求并返回预设决策。
private final class ApprovalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ApprovalRequest] = []
    var decision: ApprovalDecision = .once

    func handle(_ request: ApprovalRequest) -> ApprovalDecision {
        lock.withLock { recorded.append(request) }
        return decision
    }

    var requests: [ApprovalRequest] {
        lock.withLock { recorded }
    }
}

private func makeModeFixture(
    mode: WorkMode,
    responses: [LLMResponse],
    approval: ApprovalHandler? = nil
) throws -> (loop: AgentLoop, store: SQLiteStore, workspace: URL, mock: MockLLMClient) {
    let ws = try tempDir()
    let dbDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hiveharness-mode-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)

    var config = AppConfig.default
    config.agent.workMode = mode
    let mock = MockLLMClient(responses: responses)
    let loop = AgentLoop(
        store: store,
        config: config,
        keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)"),
        workspace: ws,
        clientOverride: mock,
        approvalHandler: approval
    )
    return (loop, store, ws, mock)
}

@Suite("审批去重")
struct ApprovalScopeTests {
    @Test("同一工具不同参数共享始终允许 key")
    func sameToolDifferentArguments() {
        let first = ApprovalRequest(
            kind: .toolExecution,
            detail: "http_get\nhttps://a.example",
            subject: "http_get"
        )
        let second = ApprovalRequest(
            kind: .toolExecution,
            detail: "http_get\nhttps://b.example",
            subject: "http_get"
        )
        #expect(first.key == second.key)

        let otherTool = ApprovalRequest(
            kind: .toolExecution,
            detail: "run_local_agent\ncodex",
            subject: "run_local_agent"
        )
        #expect(first.key != otherTool.key)
    }
}

@Suite("工作模式与审批")
struct WorkModeTests {
    @Test("模式工具矩阵")
    func allowsMatrix() {
        #expect(WorkMode.chat.allows(tool: "read_file"))
        #expect(WorkMode.chat.allows(tool: "todowrite"))
        #expect(!WorkMode.chat.allows(tool: "write_file"))
        #expect(!WorkMode.chat.allows(tool: "run_local_agent"))

        #expect(WorkMode.sandbox.allows(tool: "write_file"))
        #expect(WorkMode.sandbox.allows(tool: "read_file"))
        #expect(!WorkMode.sandbox.allows(tool: "run_local_agent"))
        #expect(!WorkMode.sandbox.allows(tool: "call_mcp"))

        #expect(WorkMode.full.allows(tool: "run_local_agent"))
        #expect(WorkMode.full.allows(tool: "write_file"))
    }

    @Test("文件策略:读可越界,写受模式限制")
    func filePolicy() async throws {
        let ws = try tempDir()
        let outside = try tempDir().appendingPathComponent("outside.txt")
        let safe = SafePath(workspace: ws)

        let sandbox = FileAccessPolicy(mode: .sandbox)
        #expect(try sandbox.resolveRead(outside.path, safePath: safe).path == outside.standardizedFileURL.path)
        await #expect(throws: ToolError.self) {
            _ = try await sandbox.resolveWrite(outside.path, safePath: safe)
        }

        let recorder = ApprovalRecorder()
        let full = FileAccessPolicy(mode: .full) { recorder.handle($0) }
        let allowed = try await full.resolveWrite(outside.path, safePath: safe)
        #expect(allowed.path == outside.standardizedFileURL.path)
        #expect(recorder.requests.first?.kind == .externalWrite)

        recorder.decision = .reject
        await #expect(throws: ToolError.self) {
            _ = try await full.resolveWrite(outside.path, safePath: safe)
        }
    }

    @Test("对话模式不向模型暴露写文件与外部执行工具")
    func chatFiltersTools() async throws {
        let fixture = try makeModeFixture(mode: .chat, responses: [LLMResponse(content: "好")])
        _ = try await fixture.loop.invoke(message: "你好")

        let names = fixture.mock.capturedToolNames().first ?? []
        #expect(names.contains("read_file"))
        #expect(names.contains("list_dir"))
        #expect(names.contains("todowrite"))
        #expect(!names.contains("write_file"))
        #expect(!names.contains("run_local_agent"))
    }

    @Test("对话模式即使模型强行调用写文件也会被拒绝")
    func chatDeniesWrite() async throws {
        let args = #"{"path":"a.txt","content":"x"}"#
        let fixture = try makeModeFixture(mode: .chat, responses: [
            LLMResponse(content: "", toolCalls: [ToolCall(name: "write_file", arguments: args)]),
            LLMResponse(content: "已拒绝"),
        ])
        let result = try await fixture.loop.invoke(message: "写文件")

        #expect(result.trace.first?.result.contains("不允许执行工具 write_file") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("a.txt").path))
    }

    @Test("安全模式拒绝写工作区外文件")
    func sandboxDeniesOutsideWrite() async throws {
        let outside = try tempDir().appendingPathComponent("outside.txt")
        let args = "{\"path\":\"\(outside.path)\",\"content\":\"x\"}"
        let fixture = try makeModeFixture(mode: .sandbox, responses: [
            LLMResponse(content: "", toolCalls: [ToolCall(name: "write_file", arguments: args)]),
            LLMResponse(content: "无法写入"),
        ])
        let result = try await fixture.loop.invoke(message: "写到外面")

        #expect(result.trace.first?.result.contains("安全模式只能写入工作区") == true)
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("完全控制模式审批后写工作区外文件")
    func fullModeApprovedWrite() async throws {
        let outside = try tempDir().appendingPathComponent("approved.txt")
        let recorder = ApprovalRecorder()
        let args = "{\"path\":\"\(outside.path)\",\"content\":\"hello\"}"
        let fixture = try makeModeFixture(
            mode: .full,
            responses: [
                LLMResponse(content: "", toolCalls: [ToolCall(name: "write_file", arguments: args)]),
                LLMResponse(content: "已写入"),
            ],
            approval: { recorder.handle($0) }
        )
        let result = try await fixture.loop.invoke(message: "写到桌面")

        #expect(result.reply == "已写入")
        #expect(recorder.requests.first?.kind == .externalWrite)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "hello")
    }

    @Test("完全控制模式拒绝外部写入时不落盘")
    func fullModeRejectedWrite() async throws {
        let outside = try tempDir().appendingPathComponent("rejected.txt")
        let recorder = ApprovalRecorder()
        recorder.decision = .reject
        let args = "{\"path\":\"\(outside.path)\",\"content\":\"hello\"}"
        let fixture = try makeModeFixture(
            mode: .full,
            responses: [
                LLMResponse(content: "", toolCalls: [ToolCall(name: "write_file", arguments: args)]),
                LLMResponse(content: "已取消"),
            ],
            approval: { recorder.handle($0) }
        )
        let result = try await fixture.loop.invoke(message: "写到桌面")

        #expect(result.trace.first?.result.contains("拒绝") == true)
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("完全控制模式执行本机 Agent 前需审批")
    func fullModeExecutionApproval() async throws {
        let recorder = ApprovalRecorder()
        recorder.decision = .reject
        let args = #"{"agent":"opencode","prompt":"hello"}"#
        let fixture = try makeModeFixture(
            mode: .full,
            responses: [
                LLMResponse(content: "", toolCalls: [ToolCall(name: "run_local_agent", arguments: args)]),
                LLMResponse(content: "已取消执行"),
            ],
            approval: { recorder.handle($0) }
        )
        let result = try await fixture.loop.invoke(message: "跑一下")

        #expect(recorder.requests.first?.kind == .toolExecution)
        #expect(result.trace.first?.result.contains("用户拒绝执行工具") == true)
    }
}
