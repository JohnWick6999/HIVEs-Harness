import Foundation
import Network

public enum GatewayError: Error, Sendable, Equatable {
    case invalidPort(UInt16)
    case startFailed(String)
}

extension GatewayError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port): return "无效端口: \(port)"
        case .startFailed(let message): return "网关启动失败: \(message)"
        }
    }
}

private enum GatewayEvent: Sendable {
    case ready
    case failed(String)
    case cancelled
}

/// 本地 OpenAI 兼容网关:仅监听 127.0.0.1,单请求单连接。
public actor LocalGateway {
    private var listener: NWListener?
    private let router: GatewayRouter
    private let queue = DispatchQueue(label: "com.shizukuclaw.gateway")

    public init(router: GatewayRouter) {
        self.router = router
    }

    /// 启动并等待 ready;端口 0 表示随机可用端口。
    public func start(port: UInt16) async throws -> UInt16 {
        if let listener, let bound = listener.port?.rawValue {
            return bound
        }
        stop()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            if port == 0 {
                listener = try NWListener(using: parameters)
            } else {
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    throw GatewayError.invalidPort(port)
                }
                listener = try NWListener(using: parameters, on: nwPort)
            }
        } catch {
            throw GatewayError.startFailed(error.localizedDescription)
        }

        let events = AsyncStream<GatewayEvent> { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield(.ready)
                case .failed(let error):
                    continuation.yield(.failed(error.localizedDescription))
                case .cancelled:
                    continuation.yield(.cancelled)
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection) }
        }

        self.listener = listener
        listener.start(queue: queue)

        for await event in events {
            switch event {
            case .ready:
                return listener.port?.rawValue ?? port
            case .failed(let message):
                self.listener = nil
                throw GatewayError.startFailed(message)
            case .cancelled:
                self.listener = nil
                throw GatewayError.startFailed("listener cancelled")
            }
        }
        throw GatewayError.startFailed("listener 结束")
    }

    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    public var isRunning: Bool { listener != nil }

    public var boundPort: UInt16? { listener?.port?.rawValue }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if (try? HTTPRequestParser.parse(buffer)) != nil {
                Task { await self.respond(buffer: buffer, connection: connection) }
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            Task { await self.receive(connection, buffer: buffer) }
        }
    }

    private func respond(buffer: Data, connection: NWConnection) async {
        guard let request = try? HTTPRequestParser.parse(buffer) else {
            sendFull(.error("bad request", status: 400), connection: connection)
            return
        }
        switch await router.routeStream(request) {
        case .response(let response):
            sendFull(response, connection: connection)
        case let .stream(status, headers, body):
            await sendStream(status: status, headers: headers, body: body, connection: connection)
        }
    }

    private func sendFull(_ response: HTTPResponse, connection: NWConnection) {
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func sendStream(
        status: Int,
        headers: [String: String],
        body: AsyncThrowingStream<String, Error>,
        connection: NWConnection
    ) async {
        var allHeaders = headers
        allHeaders["Transfer-Encoding"] = "chunked"
        allHeaders["Connection"] = "close"
        allHeaders["Server"] = "ShizukuClaw"
        var head = "HTTP/1.1 \(status) OK\r\n"
        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        guard await send(Data(head.utf8), connection: connection) else {
            connection.cancel()
            return
        }

        do {
            for try await payload in body {
                let frame = Data("data: \(payload)\n\n".utf8)
                guard await send(chunked(frame), connection: connection) else {
                    connection.cancel()
                    return
                }
            }
            _ = await send(Data("0\r\n\r\n".utf8), connection: connection)
        } catch {
            let payload = "{\"error\":{\"message\":\"stream failed\",\"type\":\"server_error\"}}"
            let frame = Data("data: \(payload)\n\n".utf8)
            _ = await send(chunked(frame), connection: connection)
            _ = await send(Data("0\r\n\r\n".utf8), connection: connection)
        }
        connection.cancel()
    }

    private func chunked(_ data: Data) -> Data {
        var output = Data("\(String(data.count, radix: 16))\r\n".utf8)
        output.append(data)
        output.append(Data("\r\n".utf8))
        return output
    }

    private func send(_ data: Data, connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                }
            )
        }
    }
}
