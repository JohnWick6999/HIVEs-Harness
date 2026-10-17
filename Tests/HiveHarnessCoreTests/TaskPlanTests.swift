import Foundation
@testable import HiveHarnessCore
import Testing

private func makeTempStore() throws -> SQLiteStore {
    let dbDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hiveharness-plan-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    return try SQLiteStore(path: dbDir.appendingPathComponent("agent.db").path)
}

private let twoStepArguments: [String: AnyCodable] = [
    "todos": AnyCodable([
        ["content": "拆分步骤", "status": "in_progress", "priority": "high"] as [String: Any],
        ["content": "写测试", "status": "pending", "priority": "medium"] as [String: Any],
    ])
]

@Suite("任务计划")
struct TaskPlanTests {
    @Test("保存/读取/删除往返")
    func storeRoundtrip() throws {
        let store = try makeTempStore()
        let plan = TaskPlan(
            items: [TaskItem(content: "写代码", status: .inProgress)],
            running: true,
            runID: "run-1"
        )
        try store.saveTaskPlan(plan, threadID: "thread", persona: "assistant")

        let loaded = try store.loadTaskPlan(threadID: "thread", persona: "assistant")
        #expect(loaded.items.count == 1)
        #expect(loaded.items.first?.content == "写代码")
        #expect(loaded.runID == "run-1")
        #expect(loaded.running)

        try store.deleteTaskPlan(threadID: "thread", persona: "assistant")
        #expect(try store.loadTaskPlan(threadID: "thread", persona: "assistant").items.isEmpty)
    }

    @Test("todowrite 写入计划并返回进度")
    func todoWritePersists() throws {
        let store = try makeTempStore()
        try store.saveTaskPlan(TaskPlan(running: true, runID: "run-1"), threadID: "t", persona: "p")
        let tool = TaskPlanTools.TodoWriteTool(store: store, threadID: "t", persona: "p", runID: "run-1")

        let result = try tool.run(arguments: twoStepArguments)

        #expect(result.text.contains("任务进度 0/2"))
        let plan = try store.loadTaskPlan(threadID: "t", persona: "p")
        #expect(plan.items.count == 2)
        #expect(plan.items.first?.status == .inProgress)
        #expect(plan.items.last?.priority == .medium)
    }

    @Test("todowrite 拒绝多个 in_progress")
    func rejectMultipleInProgress() throws {
        let store = try makeTempStore()
        try store.saveTaskPlan(TaskPlan(running: true, runID: "run-1"), threadID: "t", persona: "p")
        let tool = TaskPlanTools.TodoWriteTool(store: store, threadID: "t", persona: "p", runID: "run-1")
        let arguments: [String: AnyCodable] = [
            "todos": AnyCodable([
                ["content": "A", "status": "in_progress", "priority": "high"] as [String: Any],
                ["content": "B", "status": "in_progress", "priority": "low"] as [String: Any],
            ])
        ]

        #expect(throws: TaskPlanError.multipleInProgress) {
            try tool.run(arguments: arguments)
        }
    }

    @Test("上一轮的工具调用不能改写本轮计划")
    func rejectEndedRun() throws {
        let store = try makeTempStore()
        try store.saveTaskPlan(TaskPlan(running: false, runID: "old-run"), threadID: "t", persona: "p")
        let tool = TaskPlanTools.TodoWriteTool(store: store, threadID: "t", persona: "p", runID: "new-run")

        #expect(throws: TaskPlanError.runEnded) {
            try tool.run(arguments: twoStepArguments)
        }
    }

    @Test("AgentLoop:计划落盘并在下一轮注入系统提示词")
    func loopInjectsPlan() async throws {
        let args = #"{"todos":[{"content":"拆分步骤","status":"in_progress","priority":"high"},{"content":"写测试","status":"pending","priority":"medium"}]}"#
        let fixture = try makeAgentFixture(responses: [
            LLMResponse(content: "", toolCalls: [ToolCall(name: "todowrite", arguments: args)]),
            LLMResponse(content: "计划已建立"),
            LLMResponse(content: "继续完成"),
        ])

        let first = try await fixture.loop.invoke(message: "帮我完成两件事")
        #expect(first.reply == "计划已建立")

        var plan = try fixture.store.loadTaskPlan(threadID: "persona:assistant", persona: "assistant")
        #expect(plan.items.count == 2)
        #expect(plan.running == false)

        _ = try await fixture.loop.invoke(message: "继续")
        let request = try #require(fixture.mock.capturedMessages().last)
        let planContext = request.first {
            $0.content.plainText.contains("[当前会话任务进度]")
        }
        #expect(planContext != nil)
        #expect(planContext?.content.plainText.contains("拆分步骤") == true)

        plan = try fixture.store.loadTaskPlan(threadID: "persona:assistant", persona: "assistant")
        #expect(plan.running == false)
    }

    @Test("流式:todowrite 触发 planUpdated 与最终进度")
    func streamEmitsPlanEvents() async throws {
        let args = #"{"todos":[{"content":"拆分步骤","status":"in_progress","priority":"high"},{"content":"写测试","status":"pending","priority":"medium"}]}"#
        let store = try makeTempStore()
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let mock = MockLLMClient(
            responses: [],
            streamResponses: [
                [LLMStreamChunk(delta: "", toolCallAccumulator: [ToolCall(name: "todowrite", arguments: args)])],
                [LLMStreamChunk(delta: "计划完成")],
            ]
        )
        let loop = AgentLoop(
            store: store,
            config: .default,
            keychain: KeychainStore(service: "com.hiveharness.test.\(UUID().uuidString)"),
            workspace: ws,
            clientOverride: mock
        )

        var plans: [TaskPlan] = []
        var tools: [String] = []
        var finished: AgentResult?
        for try await event in await loop.stream(message: "做个计划") {
            switch event {
            case .planUpdated(let plan): plans.append(plan)
            case .toolCalled(let trace): tools.append(trace.tool)
            case .finished(let result): finished = result
            default: break
            }
        }

        #expect(tools == ["todowrite"])
        #expect(plans.contains { $0.items.count == 2 })
        #expect(plans.last?.running == false)
        #expect(finished?.reply == "计划完成")

        let stored = try store.loadTaskPlan(threadID: "persona:assistant", persona: "assistant")
        #expect(stored.items.count == 2)
        #expect(stored.running == false)
    }
}
