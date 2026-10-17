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

/// 把 HTTP 请求映射到 Agent。可独立测试,不依赖 Network 监听器。
public struct GatewayRouter: Sendable {
    public typealias ChatHandler = @Sendable (GatewayChatRequest) async -> GatewayChatResult

    private let models: @Sendable () -> [String]
    private let token: String?
    private let chat: ChatHandler

    public init(
        models: @escaping @Sendable () -> [String],
        token: String?,
        chat: @escaping ChatHandler
    ) {
        self.models = models
        self.token = token
        self.chat = chat
    }

    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/health" {
            return .json(["status": "ok", "service": "ShizukuClaw"])
        }
        guard authorized(request) else {
            return .error("invalid api key", status: 401, type: "authentication_error")
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            let data = models().map {
                ["id": $0, "object": "model", "owned_by": "shizuku"]
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
            return .error("当前网关只支持 stream=false(非流式)。", status: 400)
        }
        guard let messages = object["messages"] as? [[String: Any]],
              let lastUser = messages.last(where: { ($0["role"] as? String) == "user" }),
              let text = Self.extractText(lastUser["content"]),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .error("messages 中必须包含非空的 user 消息")
        }

        let persona = object["persona"] as? String
        let threadID = (object["thread_id"] as? String) ?? (object["user"] as? String)
        let model = object["model"] as? String
        let result = await chat(
            GatewayChatRequest(
                message: text,
                persona: persona,
                threadID: threadID,
                model: model
            )
        )

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

    private static func extractText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return nil
    }
}
