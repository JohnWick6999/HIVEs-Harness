import Foundation

/// 已知模型的上下文窗口(按当前主流供应商声明维护;未知模型返回 nil)。
/// 用户可在设置中关闭“自动上下文”并手动覆盖。
public enum ModelContextResolver {
    public static func contextWindow(for model: String) -> Int? {
        let name = model.lowercased()
        if name.contains("deepseek-flash") || name.contains("deepseek-v4") {
            return 100_000_000
        }
        if name.contains("deepseek-reasoner") || name.contains("deepseek-chat") {
            return 128_000
        }
        if name.contains("deepseek") { return 128_000 }
        if name.contains("gpt-4.1") { return 1_047_576 }
        if name.contains("gpt-4o") || name.contains("gpt-4-turbo") { return 128_000 }
        if name.contains("gpt-3.5") { return 16_385 }
        if name.contains("claude") { return 200_000 }
        if name.contains("gemini-1.5") || name.contains("gemini-2") { return 2_000_000 }
        if name.contains("gemini") { return 1_000_000 }
        if name.contains("qwen") { return 131_072 }
        if name.contains("kimi") || name.contains("moonshot") { return 262_144 }
        if name.contains("glm-4") { return 128_000 }
        if name.contains("llama-3.1") || name.contains("llama-3.2") { return 131_072 }
        return nil
    }

    /// 是否支持 OpenAI 兼容的 reasoning_effort 字段。
    public static func supportsReasoningEffort(for model: String) -> Bool {
        let name = model.lowercased()
        return name.contains("deepseek")
            || name.contains("o1")
            || name.contains("o3")
            || name.contains("o4")
            || name.contains("gpt-5")
            || name.contains("thinking")
    }

    public static func formatted(_ tokens: Int) -> String {
        tokens.formatted(.number.grouping(.automatic))
    }
}
