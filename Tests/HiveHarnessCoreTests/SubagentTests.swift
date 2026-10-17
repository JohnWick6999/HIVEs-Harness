import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("子代理与后台任务")
struct SubagentTests {
    @Test("单子代理返回结果")
    func single() async throws {
        let tool = RunSubagentTool { request in
            SubagentResult(title: request.title, reply: "来自 \(request.role)", success: true)
        }
        let result = try await tool.run(arguments: [
            "title": AnyCodable("调研"),
            "role": AnyCodable("researcher"),
            "prompt": AnyCodable("查资料"),
        ])
        #expect(result.text.contains("子代理完成"))
        #expect(result.text.contains("来自 researcher"))
    }

    @Test("并行集群返回所有结果")
    func cluster() async throws {
        let tool = RunSubagentClusterTool { request in
            SubagentResult(title: request.title, reply: request.prompt, success: true)
        }
        let result = try await tool.run(arguments: [
            "tasks": AnyCodable([
                ["title": "A", "prompt": "alpha"],
                ["title": "B", "prompt": "beta"],
            ]),
        ])
        #expect(result.text.contains("alpha"))
        #expect(result.text.contains("beta"))
        #expect(result.text.contains("A"))
        #expect(result.text.contains("B"))
    }

    @Test("后台任务工具返回 id")
    func background() async throws {
        let tool = SpawnAgentBackgroundTaskTool { title, _ in
            "bg_test"
        }
        let result = try await tool.run(arguments: [
            "title": AnyCodable("长任务"),
            "prompt": AnyCodable("慢慢跑"),
        ])
        #expect(result.text.contains("bg_test"))
    }

    @Test("子代理工具在所有对话模式可用")
    func visibility() {
        for mode in WorkMode.allCases {
            #expect(mode.allows(tool: "run_subagent"))
            #expect(mode.allows(tool: "run_subagent_cluster"))
            #expect(mode.allows(tool: "spawn_background_task"))
        }
    }
}
