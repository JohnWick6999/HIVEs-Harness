import Foundation

/// 当前会话累计的 AI 用量。
public struct UsageStats: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var cachedTokens: Int
    /// 模型调用轮数(含工具循环中的每一轮)
    public var modelCalls: Int
    /// 运行次数(用户发送次数)
    public var runs: Int
    /// 工具调用次数
    public var toolCalls: Int

    public init(
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        cachedTokens: Int = 0,
        modelCalls: Int = 0,
        runs: Int = 0,
        toolCalls: Int = 0
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.modelCalls = modelCalls
        self.runs = runs
        self.toolCalls = toolCalls
    }

    public static let zero = UsageStats()

    public var totalTokens: Int { promptTokens + completionTokens }

    public var cacheHitRate: Double {
        promptTokens > 0 ? min(1, max(0, Double(cachedTokens) / Double(promptTokens))) : 0
    }

    public var averageTokensPerRun: Int {
        runs > 0 ? totalTokens / runs : 0
    }

    public mutating func record(
        _ usage: LLMUsage,
        modelCalls: Int = 1,
        toolCalls: Int = 0
    ) {
        promptTokens += usage.promptTokens
        completionTokens += usage.completionTokens
        cachedTokens += usage.cachedTokens
        runs += 1
        self.modelCalls += modelCalls
        self.toolCalls += toolCalls
    }

    public mutating func reset() {
        self = .zero
    }
}
