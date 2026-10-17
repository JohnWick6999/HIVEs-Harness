import Foundation

public enum HTTPParseError: Error, Sendable, Equatable {
    case incomplete
    case malformed(String)
}

/// 极简 HTTP/1.1 请求(仅本地网关使用)。
public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    /// 键统一小写
    public let headers: [String: String]
    public let body: Data

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public enum HTTPRequestParser {
    /// 解析完整请求;数据不足时抛 `.incomplete`,调用方继续读取。
    public static func parse(_ data: Data) throws -> HTTPRequest {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw HTTPParseError.incomplete
        }
        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw HTTPParseError.malformed("请求头不是 UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPParseError.malformed("缺少请求行")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw HTTPParseError.malformed("请求行格式错误")
        }
        let target = parts[1]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else {
            throw HTTPParseError.incomplete
        }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))

        let path: String
        let query: [String: String]
        if let question = target.firstIndex(of: "?") {
            path = String(target[..<question])
            query = Self.parseQuery(String(target[target.index(after: question)...]))
        } else {
            path = target
            query = [:]
        }
        return HTTPRequest(
            method: parts[0],
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }

    private static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding, !key.isEmpty else { continue }
            let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? "") : ""
            result[key] = value
        }
        return result
    }
}

/// 极简 HTTP 响应(单次请求后关闭连接)。
public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    public static func error(
        _ message: String,
        status: Int = 400,
        type: String = "invalid_request_error"
    ) -> HTTPResponse {
        json(
            ["error": ["message": message, "type": type]],
            status: status
        )
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        allHeaders["Server"] = "HiveHarness"
        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
