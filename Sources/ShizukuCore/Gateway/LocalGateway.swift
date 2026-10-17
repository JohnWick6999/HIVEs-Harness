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
        let response: HTTPResponse
        if let request = try? HTTPRequestParser.parse(buffer) {
            response = await router.route(request)
        } else {
            response = .error("bad request", status: 400)
        }
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }
}
