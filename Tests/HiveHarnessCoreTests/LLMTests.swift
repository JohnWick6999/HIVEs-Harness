import Foundation
@testable import HiveHarnessCore
import Testing

/// 拦截 URLSession 请求的测试替身。
/// 注意:全局单例 handler + 并行测试会互相干扰,使用处必须 `.serialized`。
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// 线程安全的请求捕获盒(handler 在 URLSession 后台线程执行)。
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: URLRequest?

    func set(_ request: URLRequest) {
        lock.lock()
        _request = request
        lock.unlock()
    }

    func get() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _request
    }
}

func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// URLSession 会把 httpBody 转成 httpBodyStream,统一从这里取请求体。
func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

@Suite("LLM 类型")
struct LLMTypesTests {
    @Test("ChatContent.plainText 提取文本")
    func plainText() {
        let parts: [ChatContent.ContentPart] = [
            .init(type: .text, text: "看看这个"),
            .init(type: .imageURL, imageURL: "data:image/png;base64,xxx"),
        ]
        #expect(ChatContent.parts(parts).plainText == "看看这个\n[图片]")
    }

    @Test("AnyCodable 编解码往返")
    func anyCodable() throws {
        let original: [String: Any] = [
            "type": "object",
            "required": ["path"],
            "count": 3,
            "ratio": 0.5,
        ]
        let data = try JSONEncoder().encode(original.mapValues(AnyCodable.init))
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(decoded["type"]?.value as? String == "object")
        #expect(decoded["count"]?.value as? Int == 3)
        #expect(decoded["ratio"]?.value as? Double == 0.5)
    }
}

@Suite("LLM 客户端(串行:共享 MockURLProtocol)", .serialized)
struct LLMClientSuite {
    @Test("非流式:解析 content 与工具调用")
    func chatParsesResponse() async throws {
        let session = mockSession()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let body = """
            {"choices":[{"message":{"role":"assistant","content":"你好","tool_calls":[{"id":"call_1","type":"function","function":{"name":"list_dir","arguments":"{\\"path\\":\\".\\"}"}}]},"finish_reason":"tool_calls"}]}
            """
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = OpenAICompatibleClient(
            baseURL: "https://api.example.com/v1", apiKey: "sk-test", model: "gpt-4o-mini",
            session: session
        )
        let result = try await client.chat(
            messages: [.text(.user, "列出目录")],
            tools: [ToolSpec(name: "list_dir", description: "list files")]
        )
        #expect(result.content == "你好")
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls.first?.name == "list_dir")
        #expect(result.toolCalls.first?.arguments.contains("\"path\"") == true)
        #expect(result.finishReason == "tool_calls")
    }

    @Test("推理请求体:reasoning_effort/thinking/reasoning_content")
    func reasoningRequest() async throws {
        let session = mockSession()
        let box = RequestBox()
        MockURLProtocol.requestHandler = { request in
            box.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let body = #"{"choices":[{"message":{"content":"ok","reasoning_content":"内部思考"}}]}"#
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = OpenAICompatibleClient(
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "sk-test",
            model: "deepseek-flash",
            reasoningEffort: "max",
            thinkingEnabled: true,
            session: session
        )
        let result = try await client.chat(
            messages: [
                ChatMessage(
                    role: .assistant,
                    content: .text("先看看"),
                    reasoningContent: "上一轮思考"
                ),
                .text(.user, "继续"),
            ],
            tools: []
        )
        #expect(result.reasoningContent == "内部思考")
        let request = try #require(box.get())
        let body = try #require(bodyData(from: request))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["reasoning_effort"] as? String == "max")
        let thinking = json["thinking"] as? [String: String]
        #expect(thinking?["type"] == "enabled")
        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.first?["reasoning_content"] as? String == "上一轮思考")
    }

    @Test("非流式:请求头与端点正确")
    func chatBuildsRequest() async throws {
        let session = mockSession()
        let box = RequestBox()
        MockURLProtocol.requestHandler = { request in
            box.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = OpenAICompatibleClient(
            baseURL: "https://api.example.com/v1/", apiKey: "sk-test", model: "gpt-4o-mini",
            session: session
        )
        _ = try await client.chat(messages: [.text(.system, "sys"), .text(.user, "hi")], tools: nil)

        let request = try #require(box.get())
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(bodyData(from: request))
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "gpt-4o-mini")
        #expect((json?["messages"] as? [[String: Any]])?.count == 2)
        #expect(json?["stream"] as? Bool == false)
    }

    @Test("非流式:HTTP 错误抛出")
    func chatHTTPError() async throws {
        let session = mockSession()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("server error".utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = OpenAICompatibleClient(
            baseURL: "https://api.example.com/v1", apiKey: "sk", model: "m", session: session
        )
        await #expect(throws: LLMError.httpStatus(500, "server error")) {
            _ = try await client.chat(messages: [.text(.user, "hi")], tools: nil)
        }
    }

    @Test("流式:SSE 增量拼接与工具参数累积")
    func streamSSE() async throws {
        let session = mockSession()
        let sse = """
        data: {"choices":[{"delta":{"role":"assistant","content":"你"}}]}

        data: {"choices":[{"delta":{"content":"好"}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\\"path\\":"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"./a.txt\\"}"}}]}}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = OpenAICompatibleClient(
            baseURL: "https://api.example.com/v1", apiKey: "sk", model: "m", session: session
        )
        var text = ""
        var finalToolCalls: [ToolCall] = []
        for try await chunk in client.stream(messages: [.text(.user, "hi")], tools: nil) {
            text += chunk.delta
            if let calls = chunk.toolCallAccumulator {
                finalToolCalls = calls
            }
        }
        #expect(text == "你好")
        #expect(finalToolCalls.count == 1)
        #expect(finalToolCalls.first?.name == "read_file")
        #expect(finalToolCalls.first?.arguments.contains("./a.txt") == true)
    }

    @Test("非流式:解析 usage 与缓存命中")
    func nonStreamUsage() async throws {
        let session = mockSession()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let json = """
            {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],
             "usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,
                      "prompt_tokens_details":{"cached_tokens":80}}}
            """
            return (response, Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = OpenAICompatibleClient(
            baseURL: "https://api.example.com/v1", apiKey: "sk", model: "m", session: session
        )
        let response = try await client.chat(messages: [.text(.user, "hi")], tools: nil)
        let usage = try #require(response.usage)
        #expect(usage.promptTokens == 100)
        #expect(usage.completionTokens == 20)
        #expect(usage.cachedTokens == 80)
        #expect(abs(usage.cacheHitRate - 0.8) < 0.0001)
    }

    @Test("流式:usage-only chunk 也能被统计")
    func streamUsage() async throws {
        let session = mockSession()
        let sse = """
        data: {"choices":[{"delta":{"content":"ok"}}]}

        data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"prompt_cache_hit_tokens":6}}

        data: [DONE]

        """
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = OpenAICompatibleClient(
            baseURL: "https://api.example.com/v1", apiKey: "sk", model: "m", session: session
        )
        var usage = LLMUsage.zero
        for try await chunk in client.stream(messages: [.text(.user, "hi")], tools: nil) {
            if let chunkUsage = chunk.usage {
                usage = usage + chunkUsage
            }
        }
        #expect(usage.promptTokens == 10)
        #expect(usage.completionTokens == 5)
        #expect(usage.cachedTokens == 6)
    }

    @Test("请求走本地 11434 /v1 端点")
    func localEndpoint() async throws {
        let session = mockSession()
        let box = RequestBox()
        MockURLProtocol.requestHandler = { request in
            box.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"choices":[{"message":{"content":"本地回复"}}]}"#.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let inner = OpenAICompatibleClient(
            baseURL: "http://127.0.0.1:11434/v1", apiKey: "", model: "qwen2.5", session: session
        )
        _ = try await inner.chat(messages: [.text(.user, "hi")], tools: nil)
        let request = try #require(box.get())
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Ollama 不支持 embedding,返回 nil")
    func noEmbedding() async throws {
        let client = LocalOllamaClient()
        #expect(try await client.embed(text: "x") == nil)
    }
    @Test("Responses: 非流式解析 reasoning / output / tool call")
    func responsesChat() async throws {
        let session = mockSession()
        let box = RequestBox()
        MockURLProtocol.requestHandler = { request in
            box.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let json = #"""
            {"status":"completed","output":[
              {"type":"reasoning","content":[{"type":"reasoning_text","text":"想一想"}]},
              {"type":"message","content":[{"type":"output_text","text":"你好"}]},
              {"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"a.txt\"}"}
            ],"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15,
              "input_tokens_details":{"cached_tokens":4},
              "output_tokens_details":{"reasoning_tokens":2}}}
            """#
            return (response, Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = ResponsesAPIClient(
            baseURL: "https://api.example.com/v1", apiKey: "sk", model: "deepseek-v4-pro",
            maxOutputTokens: 2048, session: session
        )
        let result = try await client.chat(
            messages: [.text(.system, "你是助手"), .text(.user, "hi")],
            tools: [ToolSpec(name: "read_file", description: "read")]
        )
        #expect(result.content == "你好")
        #expect(result.reasoningContent == "想一想")
        #expect(result.toolCalls.first?.name == "read_file")
        #expect(result.toolCalls.first?.arguments.contains("a.txt") == true)
        #expect(result.usage?.cachedTokens == 4)
        #expect(result.finishReason == "stop")

        let request = try #require(box.get())
        #expect(request.url?.path == "/v1/responses")
        let body = try #require(bodyData(from: request))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["instructions"] as? String == "你是助手")
        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.first?["name"] as? String == "read_file")
        #expect(tools.first?["function"] == nil)
    }

    @Test("Responses: 流式 reasoning / output / function_call 累积")
    func responsesStream() async throws {
        let session = mockSession()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let sse = #"""
            event: response.reasoning_text.delta
            data: {"type":"response.reasoning_text.delta","delta":"想"}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"你好"}

            event: response.output_item.added
            data: {"type":"response.output_item.added","item":{"id":"fc1","type":"function_call","call_id":"call_1","name":"read_file","arguments":""}}

            event: response.function_call_arguments.delta
            data: {"type":"response.function_call_arguments.delta","item_id":"fc1","delta":"{\"path\":\"a.txt\"}"}

            event: response.completed
            data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":10,"output_tokens":5,"input_tokens_details":{"cached_tokens":2}}}}

            """#
            return (response, Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = ResponsesAPIClient(
            baseURL: "https://api.example.com/v1", apiKey: "sk", model: "m", session: session
        )
        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var usage = LLMUsage.zero
        for try await chunk in client.stream(messages: [.text(.user, "hi")], tools: nil) {
            text += chunk.delta
            reasoning += chunk.reasoningDelta ?? ""
            if let accumulator = chunk.toolCallAccumulator { calls = accumulator }
            if let chunkUsage = chunk.usage { usage = usage + chunkUsage }
        }
        #expect(text == "你好")
        #expect(reasoning == "想")
        #expect(calls.first?.name == "read_file")
        #expect(calls.first?.arguments.contains("a.txt") == true)
        #expect(usage.cachedTokens == 2)
    }

    @Test("Anthropic: 非流式解析 text / thinking / tool_use")
    func anthropicChat() async throws {
        let session = mockSession()
        let box = RequestBox()
        MockURLProtocol.requestHandler = { request in
            box.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let json = """
            {"type":"message","role":"assistant","content":[
              {"type":"thinking","thinking":"想"},
              {"type":"text","text":"你好"},
              {"type":"tool_use","id":"tool_1","name":"read_file","input":{"path":"a.txt"}}
            ],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3}}
            """
            return (response, Data(json.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = AnthropicAPIClient(
            baseURL: "https://api.deepseek.com", apiKey: "sk", model: "deepseek-v4-pro",
            session: session
        )
        let result = try await client.chat(
            messages: [.text(.system, "你是助手"), .text(.user, "hi")],
            tools: [ToolSpec(name: "read_file", description: "read")]
        )
        #expect(result.content == "你好")
        #expect(result.reasoningContent == "想")
        #expect(result.toolCalls.first?.name == "read_file")
        #expect(result.toolCalls.first?.arguments.contains("a.txt") == true)
        #expect(result.usage?.cachedTokens == 3)
        #expect(result.finishReason == "tool_calls")

        let request = try #require(box.get())
        #expect(request.url?.path == "/anthropic/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(bodyData(from: request))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["system"] as? String == "你是助手")
        #expect(object["max_tokens"] as? Int == 4096)
        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.first?["input_schema"] != nil)
    }

    @Test("Anthropic: 流式 text / thinking / tool_use")
    func anthropicStream() async throws {
        let session = mockSession()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let sse = #"""
            event: message_start
            data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":2}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"想"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"你好"}}

            event: content_block_start
            data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tool_1","name":"read_file","input":{}}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a.txt\"}"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}

            event: message_stop
            data: {"type":"message_stop"}

            """#
            return (response, Data(sse.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = AnthropicAPIClient(
            baseURL: "https://api.deepseek.com", apiKey: "sk", model: "m", session: session
        )
        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var usage = LLMUsage.zero
        for try await chunk in client.stream(messages: [.text(.user, "hi")], tools: nil) {
            text += chunk.delta
            reasoning += chunk.reasoningDelta ?? ""
            if let accumulator = chunk.toolCallAccumulator { calls = accumulator }
            if let chunkUsage = chunk.usage { usage = usage + chunkUsage }
        }
        #expect(text == "你好")
        #expect(reasoning == "想")
        #expect(calls.first?.name == "read_file")
        #expect(calls.first?.arguments.contains("a.txt") == true)
        #expect(usage.cachedTokens == 2)
        #expect(usage.completionTokens == 5)
    }

}
