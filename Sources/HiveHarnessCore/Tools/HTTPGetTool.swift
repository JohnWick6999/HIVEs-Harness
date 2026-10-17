import Foundation

/// 受审批保护的 HTTP GET 工具:用于天气、公共 API、文档等实时数据。
/// 只允许 http/https,拒绝本机/私网地址;响应截断,避免把超大页面塞进上下文。
public struct HTTPGetTool: Tool {
    public let name = "http_get"
    public let spec = ToolSpec(
        name: "http_get",
        description: """
        Fetch a public HTTP(S) URL for live data such as weather, APIs, or documentation. \
        Returns the response body as text (truncated). Use this instead of guessing or trying \
        local agent CLIs for network access. Private/loopback hosts are rejected.
        """,
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "url": [
                    "type": "string",
                    "description": "完整 http/https URL,例如 https://wttr.in/Yingkou?format=%l:+%c+%t+%w+%h",
                ],
            ]),
            "required": AnyCodable(["url"]),
        ]
    )

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let raw = (arguments["url"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty
        else {
            throw ToolError.invalidArguments("http_get 需要完整的 http/https URL")
        }
        guard !Self.isPrivateHost(host) else {
            throw ToolError.permissionDenied("http_get 不允许访问本机或私网地址: \(host)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("HiveHarness/0.1 (macOS Agent)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, text/html;q=0.9, application/json;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ToolError.execution("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(2_000), encoding: .utf8) ?? ""
            throw ToolError.execution("HTTP \(http.statusCode): \(body)")
        }
        let text = String(data: data.prefix(256_000), encoding: .utf8)
            ?? String(data: data.prefix(256_000), encoding: .isoLatin1)
            ?? ""
        guard !text.isEmpty else {
            return ToolResult(text: "HTTP \(http.statusCode) 返回空响应")
        }
        let capped = String(text.prefix(16_000))
        return ToolResult(text: "HTTP \(http.statusCode) \(url.absoluteString)\n\n\(capped)")
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 127 || parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }
}
