import Foundation
@testable import HiveHarnessCore
import Testing

private final class ClarificationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ClarificationRequest] = []

    func append(_ request: ClarificationRequest) {
        lock.withLock { requests.append(request) }
    }

    var all: [ClarificationRequest] {
        lock.withLock { requests }
    }
}

@Suite("主动澄清")
struct ClarificationTests {
    @Test("ask_user 回填用户选择与补充")
    func formatsAnswer() async throws {
        let box = ClarificationBox()
        let tool = AskUserTool(handler: { request in
            box.append(request)
            return ClarificationAnswer(selected: ["Swift"], freeform: "需要 macOS 原生")
        })
        let result = try await tool.run(arguments: [
            "question": AnyCodable("用哪种语言实现?"),
            "context": AnyCodable("影响依赖与发布方式"),
            "options": AnyCodable([
                ["label": "Swift", "description": "Apple 原生", "recommended": true],
                ["label": "Rust"],
            ]),
        ])

        #expect(box.all.count == 1)
        #expect(box.all.first?.options.first?.recommended == true)
        #expect(result.text.contains("用户选择: Swift"))
        #expect(result.text.contains("用户补充: 需要 macOS 原生"))
    }

    @Test("提问预算与重复问题会被拦截")
    func budgetAndDedup() async throws {
        let box = ClarificationBox()
        let tool = AskUserTool(
            handler: { request in
                box.append(request)
                return ClarificationAnswer(selected: ["A"])
            },
            gate: ClarificationGate(maxQuestions: 2)
        )
        let args: [String: AnyCodable] = [
            "question": AnyCodable("选哪个?"),
            "options": AnyCodable([["label": "A"], ["label": "B"]]),
        ]

        _ = try await tool.run(arguments: args)
        _ = try await tool.run(arguments: args)
        let third = try await tool.run(arguments: args)

        #expect(box.all.count == 1)
        #expect(third.text.contains("提问预算"))
    }

    @Test("用户跳过时给出可逆默认策略")
    func cancelled() async throws {
        let tool = AskUserTool(handler: { _ in .cancelled })
        let result = try await tool.run(arguments: [
            "question": AnyCodable("是否覆盖?"),
        ])
        #expect(result.text.contains("跳过了这个问题"))
        #expect(result.text.contains("可逆"))
    }

    @Test("有 UI 通道才暴露 ask_user 与澄清提示")
    func toolVisibility() async throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-vis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-vis-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)

        let without = MockLLMClient(responses: [LLMResponse(content: "ok")])
        let noChannel = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: without
        )
        _ = try await noChannel.invoke(message: "hi")
        #expect(without.capturedToolNames().first?.contains("ask_user") == false)
        let noChannelSystem = without.capturedMessages().first?.first?.content.plainText ?? ""
        #expect(!noChannelSystem.contains("[主动澄清]"))

        let with = MockLLMClient(responses: [LLMResponse(content: "ok")])
        let channel = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: with,
            clarificationHandler: { _ in .cancelled }
        )
        _ = try await channel.invoke(message: "hi")
        #expect(with.capturedToolNames().first?.contains("ask_user") == true)
        let withSystem = with.capturedMessages().first?.first?.content.plainText ?? ""
        #expect(withSystem.contains("[主动澄清]"))
    }

    @Test("提问偏好:关闭不暴露工具,积极提高预算")
    func modeBehavior() async throws {
        #expect(ClarificationMode.off.maxQuestions == 0)
        #expect(ClarificationMode.eager.maxQuestions == 4)

        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-mode-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)

        let offClient = MockLLMClient(responses: [LLMResponse(content: "ok")])
        let offLoop = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: offClient,
            clarificationHandler: { _ in .cancelled },
            clarificationMode: .off
        )
        _ = try await offLoop.invoke(message: "hi")
        #expect(offClient.capturedToolNames().first?.contains("ask_user") == false)
        #expect((offClient.capturedMessages().first?.first?.content.plainText ?? "").contains("[主动澄清]") == false)

        let eagerClient = MockLLMClient(responses: [LLMResponse(content: "ok")])
        let eagerLoop = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: eagerClient,
            clarificationHandler: { _ in .cancelled },
            clarificationMode: .eager
        )
        _ = try await eagerLoop.invoke(message: "hi")
        #expect(eagerClient.capturedToolNames().first?.contains("ask_user") == true)
        #expect((eagerClient.capturedMessages().first?.first?.content.plainText ?? "").contains("每轮最多 4"))
    }

    @Test("AgentLoop 提问后继续执行并写入运行日志")
    func agentLoopAsksAndContinues() async throws {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-ask-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)

        let mock = MockLLMClient(responses: [
            LLMResponse(
                content: "",
                toolCalls: [
                    ToolCall(
                        name: "ask_user",
                        arguments: #"{"question":"用哪种语言?","options":[{"label":"Swift","recommended":true},{"label":"Rust"}]}"#
                    )
                ]
            ),
            LLMResponse(content: "按 Swift 继续"),
        ])
        let box = ClarificationBox()
        let loop = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: mock,
            clarificationHandler: { request in
                box.append(request)
                return ClarificationAnswer(selected: ["Swift"])
            }
        )

        let result = try await loop.invoke(message: "实现一个命令行工具")
        #expect(result.reply == "按 Swift 继续")
        #expect(result.trace.first?.tool == "ask_user")
        #expect(result.trace.first?.result.contains("Swift") == true)
        #expect(box.all.first?.question == "用哪种语言?")

        let run = try #require(try store.listRuns(persona: "assistant").first)
        #expect(run.events.contains { $0.kind == .question })
        #expect(run.events.contains { $0.kind == .answer })
    }
}
