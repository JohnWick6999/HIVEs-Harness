import Foundation

/// 应用配置,字段对齐原版 `config/settings.yaml`。
/// 敏感字段(API Key)不在此结构内,统一走 `KeychainStore`。
public struct AppConfig: Codable, Sendable, Equatable {
    public struct LLM: Codable, Sendable, Equatable {
        /// 供应商标识:openai_compatible / ollama / openai
        public var provider: String
        /// 模型名,如 gpt-4o-mini / qwen2.5 / deepseek-chat
        public var model: String
        /// OpenAI 兼容端点,如 https://api.openai.com/v1 或本地中转
        public var baseURL: String
        /// 采样温度
        public var temperature: Double

        public init(
            provider: String = "openai_compatible",
            model: String = "gpt-4o-mini",
            baseURL: String = "https://api.openai.com/v1",
            temperature: Double = 0.4
        ) {
            self.provider = provider
            self.model = model
            self.baseURL = baseURL
            self.temperature = temperature
        }
    }

    public struct Agent: Codable, Sendable, Equatable {
        /// 工具调用最大轮数(原版 MAX_TOOL_ROUNDS = 6)
        public var maxRounds: Int
        /// 系统提示词模板
        public var systemPrompt: String
        /// 默认人格 id
        public var defaultPersona: String

        public init(
            maxRounds: Int = 6,
            systemPrompt: String = "你是一个智能助手,请根据用户意图选择工具或直接回答。",
            defaultPersona: String = "shizuku"
        ) {
            self.maxRounds = maxRounds
            self.systemPrompt = systemPrompt
            self.defaultPersona = defaultPersona
        }
    }

    public var llm: LLM
    public var agent: Agent

    public static let `default` = AppConfig()

    public init(llm: LLM = .init(), agent: Agent = .init()) {
        self.llm = llm
        self.agent = agent
    }
}

/// 配置文件读写(JSON,原生 Codable,不引第三方 YAML 依赖)。
public struct ConfigStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 读取配置;文件不存在或损坏时回退默认值(与原版静默回退行为一致)。
    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    public func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}
