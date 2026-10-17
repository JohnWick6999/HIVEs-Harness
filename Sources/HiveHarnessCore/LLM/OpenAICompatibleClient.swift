import Foundation

/// OpenAI 兼容客户端(URLSession 实现,零第三方依赖)。
/// 支持任意 OpenAI 兼容端点(官方 API / 中转 / 本地网关),对齐原版 `base_url` 设计。
public struct OpenAICompatibleClient: LLMClient {
    public let baseURL: String
    public let apiKey: String
    public let model: String
    public let temperature: Double
    public let reasoningEffort: String?
    /// DeepSeek:显式打开/关闭 thinking;nil 表示不发送。
    public let thinkingEnabled: Bool?
    private let session: URLSession

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        temperature: Double = 0.4,
        reasoningEffort: String? = nil,
        thinkingEnabled: Bool? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        self.thinkingEnabled = thinkingEnabled
        self.session = session
    }

    private var chatEndpoint: URL { URL(string: "\(baseURL)/chat/completions")! }

    /// OpenAI / DeepSeek usage 的兼容解析。
    private struct APIUsage: Decodable {
        struct PromptDetails: Decodable {
            let cached_tokens: Int?
        }
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let prompt_tokens_details: PromptDetails?
        let prompt_cache_hit_tokens: Int?
        let prompt_cache_miss_tokens: Int?

        func toLLMUsage() -> LLMUsage {
            let prompt = prompt_tokens ?? 0
            let completion = completion_tokens ?? 0
            let cached = prompt_cache_hit_tokens
                ?? prompt_tokens_details?.cached_tokens
                ?? 0
            return LLMUsage(
                promptTokens: prompt,
                completionTokens: completion,
                totalTokens: total_tokens ?? (prompt + completion),
                cachedTokens: cached
            )
        }
    }

    private func makeRequest(tools: [ToolSpec]?) -> URLRequest {
        var request = URLRequest(url: chatEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func buildBody(
        messages: [ChatMessage],
        tools: [ToolSpec]?,
        stream: Bool
    ) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map(encodeMessage),
            "temperature": temperature,
            "stream": stream,
        ]
        if stream {
            // OpenAI / DeepSeek 支持;让最后一个 chunk 带回 usage。
            payload["stream_options"] = ["include_usage": true]
        }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            payload["reasoning_effort"] = reasoningEffort
        }
        if let thinkingEnabled {
            payload["thinking"] = ["type": thinkingEnabled ? "enabled" : "disabled"]
        }
        if let tools, !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.isEmpty
                            ? ["type": "object", "properties": [:]]
                            : tool.parameters.mapValues(\.value),
                    ],
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func encodeMessage(_ message: ChatMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": message.role.rawValue]
        switch message.content {
        case .text(let text):
            dict["content"] = text
        case .parts(let parts):
            dict["content"] = parts.map { part -> [String: Any] in
                switch part.type {
                case .text:
                    return ["type": "text", "text": part.text ?? ""]
                case .imageURL:
                    return ["type": "image_url", "image_url": ["url": part.imageURL ?? ""]]
                }
            }
        }
        if message.role == .assistant,
           let reasoning = message.reasoningContent,
           !reasoning.isEmpty {
            // DeepSeek 带 tools 的思考模式要求回传上一轮 reasoning_content
            dict["reasoning_content"] = reasoning
        }
        if let calls = message.toolCalls, !calls.isEmpty {
            dict["tool_calls"] = calls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments],
                ]
            }
        }
        if let id = message.toolCallID {
            dict["tool_call_id"] = id
            // OpenAI 协议:tool 角色消息用 tool_call_id 关联
            dict["name"] = message.toolName
        }
        return dict
    }

    // MARK: - 非流式

    public func chat(messages: [ChatMessage], tools: [ToolSpec]?) async throws -> LLMResponse {
        var request = makeRequest(tools: tools)
        request.httpBody = try buildBody(messages: messages, tools: tools, stream: false)
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpStatus(http.statusCode, body)
        }

        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                    let reasoning_content: String?
                    struct ToolCall: Decodable {
                        struct Function: Decodable {
                            let name: String
                            let arguments: String?
                        }
                        let id: String
                        let function: Function
                    }
                    let tool_calls: [ToolCall]?
                }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
            let usage: APIUsage?
        }

        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let choice = decoded.choices.first else {
                throw LLMError.invalidResponse
            }
            let calls = (choice.message.tool_calls ?? []).map {
                ToolCall(id: $0.id, name: $0.function.name, arguments: $0.function.arguments ?? "{}")
            }
            return LLMResponse(
                content: choice.message.content ?? "",
                toolCalls: calls,
                finishReason: choice.finish_reason,
                usage: decoded.usage?.toLLMUsage(),
                reasoningContent: choice.message.reasoning_content
            )
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.invalidResponse
        }
    }

    // MARK: - 流式(SSE)

    public func stream(messages: [ChatMessage], tools: [ToolSpec]?) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = makeRequest(tools: tools)
                    request.httpBody = try buildBody(messages: messages, tools: tools, stream: true)
                    request.timeoutInterval = 300

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw LLMError.httpStatus(http.statusCode, "流式请求失败")
                    }

                    // 注意:不能用 bytes.lines —— 它会丢弃空行,而 SSE 事件恰好以空行(\n\n)分隔。
                    // 改为在原始字节流上扫描分隔符(兼容 \n\n 与 \r\n\r\n)。
                    var buffer = Data()
                    var toolCalls: [ToolCall] = []
                    let lfLF = Data([0x0A, 0x0A])
                    let crlfCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])

                    for try await byte in bytes {
                        buffer.append(byte)
                        // 每次追加后处理所有已完整到达的事件
                        while true {
                            // 优先匹配 \r\n\r\n,再匹配 \n\n
                            guard let range = buffer.range(of: crlfCRLF) ?? buffer.range(of: lfLF)
                            else { break }
                            let eventData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                            try processSSEEvent(eventData, toolCalls: &toolCalls) { chunk in
                                continuation.yield(chunk)
                            }
                        }
                    }
                    // 流结束,清理未闭合的尾部事件
                    if !buffer.isEmpty {
                        try processSSEEvent(buffer, toolCalls: &toolCalls) { chunk in
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 解析单个 SSE 事件块(可能含多行 data:),处理 [DONE] 与增量。
    private func processSSEEvent(
        _ eventData: Data,
        toolCalls: inout [ToolCall],
        yield: (LLMStreamChunk) -> Void
    ) throws {
        guard let text = String(data: eventData, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            if payload == "[DONE]" { continue }
            try processStreamPayload(String(payload), toolCalls: &toolCalls, yield: yield)
        }
    }

    private func processStreamPayload(
        _ payload: String,
        toolCalls: inout [ToolCall],
        yield: (LLMStreamChunk) -> Void
    ) throws {
        struct StreamResponse: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let content: String?
                    let reasoning_content: String?
                    struct ToolCall: Decodable {
                        struct Function: Decodable {
                            let name: String?
                            let arguments: String?
                        }
                        let index: Int
                        let id: String?
                        let function: Function?
                    }
                    let tool_calls: [ToolCall]?
                }
                let delta: Delta
                let finish_reason: String?
            }
            let choices: [Choice]?
            let usage: APIUsage?
        }

        guard let data = payload.data(using: .utf8) else { return }
        let decoded = try JSONDecoder().decode(StreamResponse.self, from: data)
        if let usage = decoded.usage {
            // usage-only chunk(choices 为空)也要产出,否则统计会丢。
            yield(LLMStreamChunk(delta: "", usage: usage.toLLMUsage()))
        }
        guard let choice = decoded.choices?.first else { return }

        let delta = choice.delta
        if let calls = delta.tool_calls {
            for call in calls {
                let index = call.index
                let function = call.function
                if toolCalls.indices.contains(index) {
                    // 协议约定:name 在首个 delta 中一次性完整到达;arguments 才分片累积
                    if let name = function?.name, !name.isEmpty {
                        toolCalls[index].name = name
                    }
                    if let args = function?.arguments {
                        toolCalls[index].arguments += args
                    }
                } else {
                    toolCalls.append(
                        ToolCall(
                            id: call.id ?? UUID().uuidString,
                            name: function?.name ?? "",
                            arguments: function?.arguments ?? ""
                        )
                    )
                }
            }
        }
        yield(
            LLMStreamChunk(
                delta: delta.content ?? "",
                toolCallAccumulator: toolCalls.isEmpty ? nil : toolCalls,
                finishReason: choice.finish_reason,
                reasoningDelta: delta.reasoning_content
            )
        )
    }

    // MARK: - Embedding

    public func embed(text: String) async throws -> [Double]? {
        guard let url = URL(string: "\(baseURL)/embeddings") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["model": model, "input": text]
        )
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // embedding 端点不可用时静默降级(由调用方回退 hash 向量)
            return nil
        }
        struct EmbedResponse: Decodable {
            struct Data: Decodable {
                let embedding: [Double]
            }
            let data: [Data]
        }
        guard let decoded = try? JSONDecoder().decode(EmbedResponse.self, from: data),
              let first = decoded.data.first
        else {
            return nil
        }
        return first.embedding
    }
}

/// 本地 Ollama 客户端:复用 OpenAI 兼容路径(Ollama 提供 /v1 兼容端点),零 key。
public struct LocalOllamaClient: LLMClient {
    public let model: String
    public let temperature: Double
    private let inner: OpenAICompatibleClient

    public init(model: String = "qwen2.5", temperature: Double = 0.4, host: String = "http://127.0.0.1:11434") {
        self.model = model
        self.temperature = temperature
        self.inner = OpenAICompatibleClient(
            baseURL: "\(host)/v1",
            apiKey: "",
            model: model,
            temperature: temperature
        )
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]?) async throws -> LLMResponse {
        try await inner.chat(messages: messages, tools: tools)
    }

    public func stream(messages: [ChatMessage], tools: [ToolSpec]?) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        inner.stream(messages: messages, tools: tools)
    }

    public func embed(text: String) async throws -> [Double]? {
        // Ollama 的 /v1 无 embeddings 端点,返回 nil 由上层回退 hash 向量
        nil
    }
}
