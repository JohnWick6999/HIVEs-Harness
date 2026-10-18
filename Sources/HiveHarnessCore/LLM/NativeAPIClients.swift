import Foundation

// MARK: - Shared SSE

struct NativeSSEEvent: Sendable {
    var name: String?
    var data: String
}

enum NativeSSE {
    static func events(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<NativeSSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    let lfLF = Data([0x0A, 0x0A])
                    let crlfCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])
                    for try await byte in bytes {
                        buffer.append(byte)
                        while true {
                            guard let range = buffer.range(of: crlfCRLF) ?? buffer.range(of: lfLF)
                            else { break }
                            let raw = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                            if let event = parse(raw) {
                                continuation.yield(event)
                            }
                        }
                    }
                    if let event = parse(buffer) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func parse(_ data: Data) -> NativeSSEEvent? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var name: String?
        var payloads: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
            if line.hasPrefix("event:") {
                name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                payloads.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        guard !payloads.isEmpty else { return nil }
        return NativeSSEEvent(name: name, data: payloads.joined(separator: "\n"))
    }
}

private func nativeObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func nativeArgumentsJSON(_ value: Any?) -> String {
    guard let value, JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
}

// MARK: - Responses API

/// OpenAI Responses 格式。DeepSeek 的 `/responses` 使用同一 envelope；
/// 它是无状态接口，每轮必须回传完整 input。
public struct ResponsesAPIClient: LLMClient {
    public let baseURL: String
    public let apiKey: String
    public let model: String
    public let temperature: Double
    public let reasoningEffort: String?
    public let thinkingEnabled: Bool?
    public let maxOutputTokens: Int
    private let session: URLSession

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        temperature: Double = 0.4,
        reasoningEffort: String? = nil,
        thinkingEnabled: Bool? = nil,
        maxOutputTokens: Int = 4_096,
        session: URLSession = .shared
    ) {
        var normalized = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if normalized.hasSuffix("/chat/completions") {
            normalized = String(normalized.dropLast("/chat/completions".count))
        }
        self.baseURL = normalized
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        self.thinkingEnabled = thinkingEnabled
        self.maxOutputTokens = maxOutputTokens
        self.session = session
    }

    private var endpoint: URL {
        if baseURL.hasSuffix("/responses") {
            return URL(string: baseURL)!
        }
        return URL(string: "\(baseURL)/responses")!
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func buildBody(messages: [ChatMessage], tools: [ToolSpec]?, stream: Bool) throws -> Data {
        let systemText = messages
            .filter { $0.role == .system }
            .map { $0.content.plainText }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var input: [[String: Any]] = []
        for message in messages where message.role != .system {
            switch message.role {
            case .user:
                input.append([
                    "type": "message",
                    "role": "user",
                    "content": responseContent(message.content, role: .user),
                ])
            case .assistant:
                if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                    input.append([
                        "type": "reasoning",
                        "content": [["type": "reasoning_text", "text": reasoning]],
                    ])
                }
                let parts = responseContent(message.content, role: .assistant)
                if !parts.isEmpty {
                    input.append([
                        "type": "message",
                        "role": "assistant",
                        "content": parts,
                    ])
                }
                for call in message.toolCalls ?? [] {
                    input.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.arguments,
                    ])
                }
            case .tool:
                input.append([
                    "type": "function_call_output",
                    "call_id": message.toolCallID ?? "",
                    "output": message.content.plainText,
                ])
            case .system:
                break
            }
        }

        var payload: [String: Any] = [
            "model": model,
            "input": input,
            "temperature": temperature,
            "stream": stream,
            "text": ["format": ["type": "text"]],
        ]
        if !systemText.isEmpty { payload["instructions"] = systemText }
        if maxOutputTokens > 0 { payload["max_output_tokens"] = maxOutputTokens }
        if let effort = reasoningEffort, !effort.isEmpty {
            payload["reasoning"] = ["effort": effort]
        } else if thinkingEnabled == false {
            payload["reasoning"] = ["effort": "none"]
        } else if thinkingEnabled == true {
            payload["reasoning"] = [:]
        }
        if let tools, !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters.isEmpty
                        ? ["type": "object", "properties": [:]]
                        : tool.parameters.mapValues(\.value),
                ]
            }
            payload["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func responseContent(_ content: ChatContent, role: ChatRole) -> [[String: Any]] {
        let textType = role == .assistant ? "output_text" : "input_text"
        switch content {
        case .text(let text):
            return text.isEmpty ? [] : [["type": textType, "text": text]]
        case .parts(let parts):
            return parts.compactMap { part in
                switch part.type {
                case .text:
                    guard let text = part.text, !text.isEmpty else { return nil }
                    return ["type": textType, "text": text]
                case .imageURL:
                    guard role == .user, let url = part.imageURL, !url.isEmpty else { return nil }
                    return ["type": "input_image", "image_url": url]
                }
            }
        }
    }

    private func usage(from object: [String: Any]) -> LLMUsage? {
        guard let usage = object["usage"] as? [String: Any] else { return nil }
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let total = usage["total_tokens"] as? Int ?? (input + output)
        let details = usage["input_tokens_details"] as? [String: Any]
        let cached = details?["cached_tokens"] as? Int ?? 0
        return LLMUsage(
            promptTokens: input,
            completionTokens: output,
            totalTokens: total,
            cachedTokens: cached
        )
    }

    private func finishReason(from object: [String: Any]) -> String? {
        if let reason = (object["incomplete_details"] as? [String: Any])?["reason"] as? String {
            return reason == "max_output_tokens" ? "length" : reason
        }
        switch object["status"] as? String {
        case "completed": return "stop"
        case "failed": return "error"
        case "incomplete": return "length"
        default: return nil
        }
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]?) async throws -> LLMResponse {
        var request = makeRequest()
        request.httpBody = try buildBody(messages: messages, tools: tools, stream: false)
        request.timeoutInterval = 180
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = nativeObject(data), let output = object["output"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }

        var content = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        for item in output {
            switch item["type"] as? String {
            case "reasoning":
                for part in item["content"] as? [[String: Any]] ?? [] {
                    if part["type"] as? String == "reasoning_text" {
                        reasoning += part["text"] as? String ?? ""
                    }
                }
            case "message":
                for part in item["content"] as? [[String: Any]] ?? [] {
                    if part["type"] as? String == "output_text" {
                        content += part["text"] as? String ?? ""
                    }
                }
            case "function_call":
                let id = item["call_id"] as? String ?? item["id"] as? String ?? UUID().uuidString
                let name = item["name"] as? String ?? ""
                let arguments = item["arguments"] as? String ?? "{}"
                calls.append(ToolCall(id: id, name: name, arguments: arguments))
            default:
                break
            }
        }
        return LLMResponse(
            content: content,
            toolCalls: calls,
            finishReason: finishReason(from: object),
            usage: usage(from: object),
            reasoningContent: reasoning.isEmpty ? nil : reasoning
        )
    }

    public func stream(messages: [ChatMessage], tools: [ToolSpec]?) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = makeRequest()
                    request.httpBody = try buildBody(messages: messages, tools: tools, stream: true)
                    request.timeoutInterval = 300
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw LLMError.httpStatus(http.statusCode, "Responses 流式请求失败")
                    }

                    var accumulated: [ToolCall] = []
                    var indices: [String: Int] = [:]
                    for try await event in NativeSSE.events(from: bytes) {
                        guard let object = nativeObject(Data(event.data.utf8)) else { continue }
                        let type = (object["type"] as? String) ?? event.name ?? ""
                        switch type {
                        case "response.reasoning_text.delta":
                            if let delta = object["delta"] as? String, !delta.isEmpty {
                                continuation.yield(LLMStreamChunk(delta: "", reasoningDelta: delta))
                            }
                        case "response.output_text.delta":
                            if let delta = object["delta"] as? String, !delta.isEmpty {
                                continuation.yield(LLMStreamChunk(delta: delta))
                            }
                        case "response.output_item.added", "response.output_item.done":
                            guard let item = object["item"] as? [String: Any],
                                  item["type"] as? String == "function_call" else { continue }
                            let itemID = item["id"] as? String ?? UUID().uuidString
                            let callID = item["call_id"] as? String ?? itemID
                            let name = item["name"] as? String ?? ""
                            let arguments = item["arguments"] as? String ?? ""
                            if let index = indices[itemID] {
                                accumulated[index].name = name.isEmpty ? accumulated[index].name : name
                                accumulated[index].arguments = arguments.isEmpty ? accumulated[index].arguments : arguments
                            } else {
                                indices[itemID] = accumulated.count
                                accumulated.append(ToolCall(id: callID, name: name, arguments: arguments))
                            }
                            continuation.yield(LLMStreamChunk(delta: "", toolCallAccumulator: accumulated))
                        case "response.function_call_arguments.delta":
                            let itemID = object["item_id"] as? String ?? ""
                            guard let index = indices[itemID] else { continue }
                            accumulated[index].arguments += object["delta"] as? String ?? ""
                            continuation.yield(LLMStreamChunk(delta: "", toolCallAccumulator: accumulated))
                        case "response.function_call_arguments.done":
                            let itemID = object["item_id"] as? String ?? ""
                            guard let index = indices[itemID] else { continue }
                            if let arguments = object["arguments"] as? String {
                                accumulated[index].arguments = arguments
                            }
                            continuation.yield(LLMStreamChunk(delta: "", toolCallAccumulator: accumulated))
                        case "response.completed", "response.incomplete":
                            if let responseObject = object["response"] as? [String: Any],
                               let use = usage(from: responseObject) {
                                continuation.yield(
                                    LLMStreamChunk(
                                        delta: "",
                                        finishReason: finishReason(from: responseObject),
                                        usage: use
                                    )
                                )
                            } else {
                                continuation.yield(
                                    LLMStreamChunk(delta: "", finishReason: type == "response.completed" ? "stop" : "length")
                                )
                            }
                        case "response.failed":
                            let message = ((object["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                            throw LLMError.transport(message ?? "Responses 流式请求失败")
                        default:
                            break
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

    public func embed(text: String) async throws -> [Double]? { nil }
}

// MARK: - Anthropic Messages API

/// Anthropic Messages 格式；DeepSeek 的 base_url 为 `https://api.deepseek.com/anthropic`。
public struct AnthropicAPIClient: LLMClient {
    public let baseURL: String
    public let apiKey: String
    public let model: String
    public let temperature: Double
    public let reasoningEffort: String?
    public let thinkingEnabled: Bool?
    public let maxOutputTokens: Int
    private let session: URLSession

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        temperature: Double = 0.4,
        reasoningEffort: String? = nil,
        thinkingEnabled: Bool? = nil,
        maxOutputTokens: Int = 4_096,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        self.thinkingEnabled = thinkingEnabled
        self.maxOutputTokens = maxOutputTokens
        self.session = session
    }

    private var endpoint: URL {
        var base = baseURL
        if base.hasSuffix("/v1/messages") { return URL(string: base)! }
        if let host = URL(string: base)?.host, host.contains("api.deepseek.com") {
            if base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
            if !base.contains("/anthropic") { base += "/anthropic" }
        }
        if base.hasSuffix("/v1") {
            return URL(string: "\(base)/messages")!
        }
        if base.hasSuffix("/anthropic") {
            return URL(string: "\(base)/v1/messages")!
        }
        return URL(string: "\(base)/v1/messages")!
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        return request
    }

    private func buildBody(messages: [ChatMessage], tools: [ToolSpec]?, stream: Bool) throws -> Data {
        let systemText = messages
            .filter { $0.role == .system }
            .map { $0.content.plainText }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var converted: [[String: Any]] = []
        func appendUser(_ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if var last = converted.last,
               last["role"] as? String == "user",
               var content = last["content"] as? [[String: Any]] {
                content.append(contentsOf: blocks)
                last["content"] = content
                converted[converted.count - 1] = last
            } else {
                converted.append(["role": "user", "content": blocks])
            }
        }

        for message in messages where message.role != .system {
            switch message.role {
            case .user:
                appendUser(anthropicContent(message.content, role: .user))
            case .assistant:
                var blocks = anthropicContent(message.content, role: .assistant)
                for call in message.toolCalls ?? [] {
                    var input: Any = [:]
                    if let data = call.arguments.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) {
                        input = object
                    }
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": input,
                    ])
                }
                if !blocks.isEmpty {
                    converted.append(["role": "assistant", "content": blocks])
                }
            case .tool:
                let result: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": message.toolCallID ?? "",
                    "content": message.content.plainText,
                ]
                appendUser([result])
            case .system:
                break
            }
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": converted,
            "max_tokens": maxOutputTokens,
            "temperature": temperature,
            "stream": stream,
        ]
        if !systemText.isEmpty { payload["system"] = systemText }
        if let effort = reasoningEffort, !effort.isEmpty {
            payload["output_config"] = ["effort": effort]
        }
        if let thinkingEnabled {
            var thinking: [String: Any] = ["type": thinkingEnabled ? "enabled" : "disabled"]
            if thinkingEnabled {
                thinking["budget_tokens"] = max(1024, maxOutputTokens / 4)
            }
            payload["thinking"] = thinking
        }
        if let tools, !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parameters.isEmpty
                        ? ["type": "object", "properties": [:]]
                        : tool.parameters.mapValues(\.value),
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func anthropicContent(_ content: ChatContent, role: ChatRole) -> [[String: Any]] {
        switch content {
        case .text(let text):
            return text.isEmpty ? [] : [["type": "text", "text": text]]
        case .parts(let parts):
            return parts.compactMap { part in
                switch part.type {
                case .text:
                    guard let text = part.text, !text.isEmpty else { return nil }
                    return ["type": "text", "text": text]
                case .imageURL:
                    return anthropicImage(part.imageURL)
                }
            }
        }
    }

    private func anthropicImage(_ url: String?) -> [String: Any]? {
        guard let url, !url.isEmpty else { return nil }
        if url.hasPrefix("data:image/") {
            guard let comma = url.firstIndex(of: ",") else { return nil }
            let header = String(url[url.startIndex..<comma])
            let data = String(url[url.index(after: comma)...])
            let media = header
                .replacingOccurrences(of: "data:", with: "")
                .replacingOccurrences(of: ";base64", with: "")
            return [
                "type": "image",
                "source": ["type": "base64", "media_type": media, "data": data],
            ]
        }
        return ["type": "image", "source": ["type": "url", "url": url]]
    }

    private func usage(from object: [String: Any]) -> LLMUsage? {
        guard let usage = object["usage"] as? [String: Any] else { return nil }
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cached = usage["cache_read_input_tokens"] as? Int ?? 0
        return LLMUsage(
            promptTokens: input,
            completionTokens: output,
            totalTokens: input + output,
            cachedTokens: cached
        )
    }

    private func finishReason(_ reason: String?) -> String? {
        switch reason {
        case "tool_use": return "tool_calls"
        case "end_turn", "stop_sequence": return "stop"
        case "max_tokens": return "length"
        default: return reason
        }
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]?) async throws -> LLMResponse {
        var request = makeRequest()
        request.httpBody = try buildBody(messages: messages, tools: tools, stream: false)
        request.timeoutInterval = 180
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = nativeObject(data), let blocks = object["content"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }

        var content = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                content += block["text"] as? String ?? ""
            case "thinking":
                reasoning += block["thinking"] as? String ?? ""
            case "tool_use":
                calls.append(
                    ToolCall(
                        id: block["id"] as? String ?? UUID().uuidString,
                        name: block["name"] as? String ?? "",
                        arguments: nativeArgumentsJSON(block["input"])
                    )
                )
            default:
                break
            }
        }
        return LLMResponse(
            content: content,
            toolCalls: calls,
            finishReason: finishReason(object["stop_reason"] as? String),
            usage: usage(from: object),
            reasoningContent: reasoning.isEmpty ? nil : reasoning
        )
    }

    public func stream(messages: [ChatMessage], tools: [ToolSpec]?) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = makeRequest()
                    request.httpBody = try buildBody(messages: messages, tools: tools, stream: true)
                    request.timeoutInterval = 300
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw LLMError.httpStatus(http.statusCode, "Anthropic 流式请求失败")
                    }

                    var inputTokens = 0
                    var cachedTokens = 0
                    var outputTokens = 0
                    var calls: [ToolCall] = []
                    var toolIndices: [Int: Int] = [:]
                    var sawFinalUsage = false

                    for try await event in NativeSSE.events(from: bytes) {
                        guard let object = nativeObject(Data(event.data.utf8)) else { continue }
                        let type = (object["type"] as? String) ?? event.name ?? ""
                        switch type {
                        case "message_start":
                            if let message = object["message"] as? [String: Any],
                               let use = usage(from: message) {
                                inputTokens = use.promptTokens
                                cachedTokens = use.cachedTokens
                            }
                        case "content_block_start":
                            let index = object["index"] as? Int ?? calls.count
                            guard let block = object["content_block"] as? [String: Any] else { continue }
                            if block["type"] as? String == "tool_use" {
                                toolIndices[index] = calls.count
                                calls.append(
                                    ToolCall(
                                        id: block["id"] as? String ?? UUID().uuidString,
                                        name: block["name"] as? String ?? "",
                                        arguments: nativeArgumentsJSON(block["input"])
                                    )
                                )
                                continuation.yield(LLMStreamChunk(delta: "", toolCallAccumulator: calls))
                            }
                        case "content_block_delta":
                            guard let delta = object["delta"] as? [String: Any] else { continue }
                            switch delta["type"] as? String {
                            case "text_delta":
                                if let text = delta["text"] as? String, !text.isEmpty {
                                    continuation.yield(LLMStreamChunk(delta: text))
                                }
                            case "thinking_delta":
                                if let text = delta["thinking"] as? String, !text.isEmpty {
                                    continuation.yield(LLMStreamChunk(delta: "", reasoningDelta: text))
                                }
                            case "input_json_delta":
                                let index = object["index"] as? Int ?? 0
                                guard let callIndex = toolIndices[index] else { continue }
                                calls[callIndex].arguments += delta["partial_json"] as? String ?? ""
                                continuation.yield(LLMStreamChunk(delta: "", toolCallAccumulator: calls))
                            default:
                                break
                            }
                        case "message_delta":
                            if let use = object["usage"] as? [String: Any] {
                                outputTokens = use["output_tokens"] as? Int ?? outputTokens
                            }
                            let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String
                            let combined = LLMUsage(
                                promptTokens: inputTokens,
                                completionTokens: outputTokens,
                                totalTokens: inputTokens + outputTokens,
                                cachedTokens: cachedTokens
                            )
                            sawFinalUsage = true
                            continuation.yield(
                                LLMStreamChunk(
                                    delta: "",
                                    finishReason: finishReason(reason),
                                    usage: combined
                                )
                            )
                        case "error":
                            let message = (object["error"] as? [String: Any])?["message"] as? String
                            throw LLMError.transport(message ?? "Anthropic 流式请求失败")
                        default:
                            break
                        }
                    }
                    if !sawFinalUsage, inputTokens + outputTokens > 0 {
                        continuation.yield(
                            LLMStreamChunk(
                                delta: "",
                                finishReason: nil,
                                usage: LLMUsage(
                                    promptTokens: inputTokens,
                                    completionTokens: outputTokens,
                                    totalTokens: inputTokens + outputTokens,
                                    cachedTokens: cachedTokens
                                )
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func embed(text: String) async throws -> [Double]? { nil }
}
