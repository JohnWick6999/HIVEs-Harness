import Foundation
@testable import ShizukuCore
import Testing

private func rawRequest(
    method: String = "POST",
    target: String = "/v1/chat/completions",
    headers: [String: String] = [:],
    body: String = ""
) -> Data {
    var head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    var allHeaders = headers
    allHeaders["Content-Length"] = String(body.utf8.count)
    for (key, value) in allHeaders {
        head += "\(key): \(value)\r\n"
    }
    head += "\r\n"
    return Data((head + body).utf8)
}

private func jsonBody(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func decodedJSON(_ response: HTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
}

@Suite("本地网关")
struct GatewayTests {
    @Test("HTTP 请求解析:请求行、查询串、头、正文")
    func parseRequest() throws {
        let request = try HTTPRequestParser.parse(
            rawRequest(
                target: "/v1/chat/completions?x=1&y=hello%20world",
                headers: ["Authorization": "Bearer t", "Content-Type": "application/json"],
                body: #"{"a":1}"#
            )
        )
        #expect(request.method == "POST")
        #expect(request.path == "/v1/chat/completions")
        #expect(request.query["x"] == "1")
        #expect(request.query["y"] == "hello world")
        #expect(request.headers["authorization"] == "Bearer t")
        #expect(String(data: request.body, encoding: .utf8) == #"{"a":1}"#)
    }

    @Test("正文不完整时返回 incomplete")
    func incompleteBody() {
        let data = Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)
        #expect(throws: HTTPParseError.incomplete) {
            _ = try HTTPRequestParser.parse(data)
        }
    }

    @Test("路由:/v1/models 与 chat/completions")
    func routes() async {
        let router = GatewayRouter(
            models: { ["model-a", "model-b"] },
            token: nil,
            chat: { request in
                GatewayChatResult(
                    reply: "echo:\(request.message)",
                    model: request.model ?? "model-a",
                    promptTokens: 3,
                    completionTokens: 5
                )
            }
        )

        let modelsResponse = await router.route(
            HTTPRequest(method: "GET", path: "/v1/models")
        )
        #expect(modelsResponse.status == 200)
        let modelsJSON = decodedJSON(modelsResponse)
        #expect((modelsJSON["data"] as? [[String: Any]])?.count == 2)

        let body = jsonBody([
            "model": "model-b",
            "messages": [
                ["role": "system", "content": "sys"],
                ["role": "user", "content": "你好"],
            ],
            "stream": false,
        ])
        let chatResponse = await router.route(
            HTTPRequest(method: "POST", path: "/v1/chat/completions", body: body)
        )
        #expect(chatResponse.status == 200)
        let chatJSON = decodedJSON(chatResponse)
        #expect((chatJSON["model"] as? String) == "model-b")
        let choice = (chatJSON["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        #expect((message?["content"] as? String) == "echo:你好")
        let usage = chatJSON["usage"] as? [String: Any]
        #expect((usage?["total_tokens"] as? Int) == 8)
    }

    @Test("鉴权:配置 token 后必须 Bearer")
    func tokenAuth() async {
        let router = GatewayRouter(
            models: { ["m"] },
            token: "secret",
            chat: { _ in GatewayChatResult(reply: "ok", model: "m") }
        )
        let unauthorized = await router.route(
            HTTPRequest(method: "GET", path: "/v1/models")
        )
        #expect(unauthorized.status == 401)

        let authorized = await router.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/models",
                headers: ["authorization": "Bearer secret"]
            )
        )
        #expect(authorized.status == 200)
    }

    @Test("SSE 流式:增量 chunk 以 data: 行输出")
    func streamingRoute() async throws {
        let router = GatewayRouter(
            models: { ["model-a"] },
            token: nil,
            chat: { _ in GatewayChatResult(reply: "fallback", model: "model-a") },
            streamChat: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.delta("你"))
                    continuation.yield(.delta("好"))
                    continuation.yield(.finished(
                        model: "model-a",
                        reply: "你好",
                        promptTokens: 2,
                        completionTokens: 3
                    ))
                    continuation.finish()
                }
            }
        )
        let body = jsonBody([
            "stream": true,
            "messages": [["role": "user", "content": "hi"]],
        ])
        let route = await router.routeStream(
            HTTPRequest(method: "POST", path: "/v1/chat/completions", body: body)
        )
        guard case let .stream(status, headers, stream) = route else {
            Issue.record("expected SSE stream")
            return
        }
        #expect(status == 200)
        #expect(headers["Content-Type"]?.contains("text/event-stream") == true)

        var payloads: [String] = []
        for try await payload in stream {
            payloads.append(payload)
        }
        #expect(payloads.contains { $0.contains("\"content\":\"你\"") })
        #expect(payloads.contains { $0.contains("\"finish_reason\":\"stop\"") })
        #expect(payloads.last == "[DONE]")
    }

    @Test("stream=true 明确拒绝,未知路由 404")
    func rejections() async {
        let router = GatewayRouter(
            models: { [] },
            token: nil,
            chat: { _ in GatewayChatResult(reply: "", model: "") }
        )
        let streamBody = jsonBody([
            "stream": true,
            "messages": [["role": "user", "content": "hi"]],
        ])
        let streamResponse = await router.route(
            HTTPRequest(method: "POST", path: "/v1/chat/completions", body: streamBody)
        )
        #expect(streamResponse.status == 400)

        let notFound = await router.route(
            HTTPRequest(method: "GET", path: "/nope")
        )
        #expect(notFound.status == 404)
    }

    @Test("真实监听 SSE:分块输出并被客户端读取")
    func listenerStreaming() async throws {
        let router = GatewayRouter(
            models: { ["m"] },
            token: nil,
            chat: { _ in GatewayChatResult(reply: "fallback", model: "m") },
            streamChat: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.delta("流"))
                    continuation.yield(.delta("式"))
                    continuation.yield(.finished(model: "m", reply: "流式", promptTokens: 1, completionTokens: 2))
                    continuation.finish()
                }
            }
        )
        let gateway = LocalGateway(router: router)
        let port = try await gateway.start(port: 0)
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody([
            "stream": true,
            "messages": [["role": "user", "content": "hi"]],
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var payloads: [String] = []
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            payloads.append(String(line.dropFirst(6)))
        }
        #expect(payloads.contains { $0.contains("\"content\":\"流\"") })
        #expect(payloads.contains("[DONE]"))
        await gateway.stop()
    }

    @Test("真实监听 127.0.0.1 并响应 /health")
    func listenerHealth() async throws {
        let router = GatewayRouter(
            models: { ["m"] },
            token: nil,
            chat: { _ in GatewayChatResult(reply: "ok", model: "m") }
        )
        let gateway = LocalGateway(router: router)
        let port = try await gateway.start(port: 0)
        #expect(port > 0)

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/health"))
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        #expect((json?["status"] as? String) == "ok")

        await gateway.stop()
    }
}
