import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("推理等级")
struct ReasoningTests {
    @Test("等级映射与默认配置")
    func mapping() {
        #expect(ReasoningEffort.off.apiValue == nil)
        #expect(ReasoningEffort.low.apiValue == "low")
        #expect(ReasoningEffort.medium.apiValue == "medium")
        #expect(ReasoningEffort.high.apiValue == "high")
        #expect(ReasoningEffort.max.apiValue == "high")
        #expect(ReasoningEffort.max.deepSeekValue == "max")
        #expect(ReasoningEffort.medium.deepSeekValue == "medium")
        #expect(AppConfig.default.agent.reasoningEffort == .medium)
    }

    @Test("只对支持 reasoning_effort 的模型启用")
    func support() {
        #expect(ModelContextResolver.supportsReasoningEffort(for: "deepseek-flash"))
        #expect(ModelContextResolver.supportsReasoningEffort(for: "gpt-5"))
        #expect(!ModelContextResolver.supportsReasoningEffort(for: "gpt-4o-mini"))
    }
}
