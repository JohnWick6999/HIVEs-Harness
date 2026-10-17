import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("AI 用量")
struct UsageTests {
    @Test("LLMUsage 累加与缓存命中率")
    func usageMath() {
        let usage = LLMUsage(
            promptTokens: 100,
            completionTokens: 20,
            cachedTokens: 80
        )
        #expect(usage.totalTokens == 120)
        #expect(abs(usage.cacheHitRate - 0.8) < 0.0001)

        let sum = usage + LLMUsage(promptTokens: 50, completionTokens: 10, cachedTokens: 20)
        #expect(sum.promptTokens == 150)
        #expect(sum.completionTokens == 30)
        #expect(sum.cachedTokens == 100)
        #expect(sum.totalTokens == 180)
    }

    @Test("会话用量统计与重置")
    func stats() {
        var stats = UsageStats.zero
        stats.record(
            LLMUsage(promptTokens: 100, completionTokens: 20, cachedTokens: 80),
            modelCalls: 2,
            toolCalls: 1
        )
        stats.record(
            LLMUsage(promptTokens: 50, completionTokens: 10, cachedTokens: 0),
            modelCalls: 1,
            toolCalls: 3
        )
        #expect(stats.totalTokens == 180)
        #expect(stats.cachedTokens == 80)
        #expect(stats.modelCalls == 3)
        #expect(stats.runs == 2)
        #expect(stats.toolCalls == 4)
        #expect(stats.averageTokensPerRun == 90)

        stats.reset()
        #expect(stats == .zero)
    }

    @Test("上下文圆环优先显示实际 prompt token")
    func contextDisplay() {
        var state = SessionContextState(
            estimatedTokens: 1_000,
            contextLimit: 10_000,
            budget: 8_000,
            usagePercent: 10
        )
        #expect(state.displayTokens == 1_000)
        #expect(state.displayPercent == 10)
        #expect(!state.isActualUsage)

        state.actualPromptTokens = 8_000
        state.actualCompletionTokens = 200
        #expect(state.displayTokens == 8_000)
        #expect(state.displayPercent == 80)
        #expect(state.isActualUsage)
    }

    @Test("AgentLoop 返回真实 usage 与模型轮数")
    func agentUsage() async throws {
        let usage = LLMUsage(
            promptTokens: 120,
            completionTokens: 30,
            cachedTokens: 100
        )
        let fixture = try makeAgentFixture(responses: [
            LLMResponse(content: "好的", usage: usage),
        ])
        let result = try await fixture.loop.invoke(message: "你好")
        #expect(result.usage == usage)
        #expect(result.lastUsage == usage)
        #expect(result.modelCalls == 1)
    }
}
