/// HiveHarnessCore —— HiveHarness 的共享引擎库。
///
/// 模块划分:
/// - Config:   配置加载 + Keychain 敏感信息存储
/// - LLM:     大模型客户端抽象(OpenAI 兼容 / 本地 Ollama)
/// - Storage:  SQLite 存储 + 长期记忆检索
/// - Tools:    Agent 工具协议 + 注册表 + 内置工具
/// - Agent:    工具循环 Agent 核心
/// - Persona:  人格系统
/// - MCP:      MCP 协议客户端(JSON-RPC 2.0)
/// - Plugin:   插件清单与策略
public enum HiveHarnessCore {
    /// 核心库版本号,与 App 产品版本解耦
    public static let version = "0.1.0"
}
