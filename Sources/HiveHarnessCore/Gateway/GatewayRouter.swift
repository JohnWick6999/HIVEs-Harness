import Foundation

/// 网关侧的对话请求(已从 OpenAI 格式归一化)。
public struct GatewayChatRequest: Sendable, Equatable {
    public var message: String
    public var persona: String?
    public var threadID: String?
    public var model: String?

    public init(message: String, persona: String? = nil, threadID: String? = nil, model: String? = nil) {
        self.message = message
        self.persona = persona
        self.threadID = threadID
        self.model = model
    }
}

public struct GatewayChatResult: Sendable, Equatable {
    public var reply: String
    public var model: String
    public var promptTokens: Int
    public var completionTokens: Int

    public init(reply: String, model: String, promptTokens: Int = 0, completionTokens: Int = 0) {
        self.reply = reply
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// 流式增量事件。
public enum GatewayStreamEvent: Sendable {
    case delta(String)
    case finished(
        model: String,
        reply: String,
        promptTokens: Int,
        completionTokens: Int
    )
}

/// 路由结果:普通响应或 SSE 流。
public enum GatewayRoute: Sendable {
    case response(HTTPResponse)
    case stream(status: Int, headers: [String: String], body: AsyncThrowingStream<String, Error>)
}

/// 把 HTTP 请求映射到 Agent。可独立测试,不依赖 Network 监听器。
public struct GatewayRouter: Sendable {
    public typealias ChatHandler = @Sendable (GatewayChatRequest) async -> GatewayChatResult
    public typealias StreamHandler = @Sendable (GatewayChatRequest) -> AsyncThrowingStream<GatewayStreamEvent, Error>

    private let models: @Sendable () -> [String]
    private let token: String?
    private let chat: ChatHandler
    private let streamChat: StreamHandler?

    public init(
        models: @escaping @Sendable () -> [String],
        token: String?,
        chat: @escaping ChatHandler,
        streamChat: StreamHandler? = nil
    ) {
        self.models = models
        self.token = token
        self.chat = chat
        self.streamChat = streamChat
    }

    /// 流式路由:仅 `POST /v1/chat/completions` + `stream=true` 走 SSE,其余复用普通路由。
    public func routeStream(_ request: HTTPRequest) async -> GatewayRoute {
        guard request.method == "POST",
              request.path == "/v1/chat/completions",
              let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              (object["stream"] as? Bool) == true,
              let streamChat
        else {
            return .response(await route(request))
        }
        guard authorized(request) else {
            return .response(.error("invalid api key", status: 401, type: "authentication_error"))
        }
        guard let chatRequest = Self.parseChatRequest(object) else {
            return .response(.error("messages 中必须包含非空的 user 消息"))
        }
        let fallbackModel = chatRequest.model ?? models().first ?? "hive"
        return .stream(
            status: 200,
            headers: [
                "Content-Type": "text/event-stream; charset=utf-8",
                "Cache-Control": "no-cache",
            ],
            body: Self.sse(streamChat(chatRequest), fallbackModel: fallbackModel)
        )
    }

    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/health" {
            return .json(["status": "ok", "service": "HiveHarness"])
        }
        guard authorized(request) else {
            return .error("invalid api key", status: 401, type: "authentication_error")
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            let data = models().map {
                ["id": $0, "object": "model", "owned_by": "hive"]
            }
            return .json(["object": "list", "data": data])

        case ("POST", "/v1/chat/completions"):
            return await handleChat(request)

        default:
            return .error("not found: \(request.method) \(request.path)", status: 404, type: "not_found")
        }
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        guard let token, !token.isEmpty else { return true }
        let header = request.headers["authorization"] ?? ""
        return header == "Bearer \(token)"
    }

    private func handleChat(_ request: HTTPRequest) async -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return .error("请求体必须是 JSON 对象")
        }
        if let stream = object["stream"] as? Bool, stream {
            return .error("当前网关未启用流式处理器;请先启动支持 SSE 的版本。", status: 400)
        }
        guard let chatRequest = Self.parseChatRequest(object) else {
            return .error("messages 中必须包含非空的 user 消息")
        }
        let result = await chat(chatRequest)

        let created = Int(Date().timeIntervalSince1970)
        let promptTokens = result.promptTokens
        let completionTokens = result.completionTokens
        let payload: [String: Any] = [
            "id": "chatcmpl-" + UUID().uuidString.lowercased(),
            "object": "chat.completion",
            "created": created,
            "model": result.model,
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": result.reply],
                    "finish_reason": "stop",
                ]
            ],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ],
        ]
        return .json(payload)
    }

    private static func parseChatRequest(_ object: [String: Any]) -> GatewayChatRequest? {
        guard let messages = object["messages"] as? [[String: Any]],
              let lastUser = messages.last(where: { ($0["role"] as? String) == "user" }),
              let text = extractText(lastUser["content"]),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return GatewayChatRequest(
            message: text,
            persona: object["persona"] as? String,
            threadID: (object["thread_id"] as? String) ?? (object["user"] as? String),
            model: object["model"] as? String
        )
    }

    private static func sse(
        _ events: AsyncThrowingStream<GatewayStreamEvent, Error>,
        fallbackModel: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let id = "chatcmpl-" + UUID().uuidString.lowercased()
                let created = Int(Date().timeIntervalSince1970)
                var model = fallbackModel
                do {
                    for try await event in events {
                        switch event {
                        case .delta(let text):
                            continuation.yield(
                                jsonString(
                                    chunk(
                                        id: id,
                                        created: created,
                                        model: model,
                                        delta: ["content": text],
                                        finishReason: nil,
                                        usage: nil
                                    )
                                )
                            )
                        case let .finished(finishedModel, _, promptTokens, completionTokens):
                            model = finishedModel
                            continuation.yield(
                                jsonString(
                                    chunk(
                                        id: id,
                                        created: created,
                                        model: model,
                                        delta: [:],
                                        finishReason: "stop",
                                        usage: [
                                            "prompt_tokens": promptTokens,
                                            "completion_tokens": completionTokens,
                                            "total_tokens": promptTokens + completionTokens,
                                        ]
                                    )
                                )
                            )
                        }
                    }
                    continuation.yield("[DONE]")
                    continuation.finish()
                } catch {
                    continuation.yield(
                        jsonString([
                            "error": [
                                "message": error.localizedDescription,
                                "type": "server_error",
                            ]
                        ])
                    )
                    continuation.yield("[DONE]")
                    continuation.finish()
                }
            }
        }
    }

    private static func chunk(
        id: String,
        created: Int,
        model: String,
        delta: [String: Any],
        finishReason: String?,
        usage: [String: Int]?
    ) -> [String: Any] {
        let finish: Any = finishReason ?? NSNull()
        var payload: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "delta": delta,
                    "finish_reason": finish,
                ]
            ],
        ]
        if let usage {
            payload["usage"] = usage
        }
        return payload
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func extractText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return nil
    }
}
