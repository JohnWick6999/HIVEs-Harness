import Foundation

/// MCP 协议错误
public enum MCPError: Error, Sendable, Equatable {
    case notConnected
    case unsupportedTransport(String)
    case rpcError(Int, String)
    case timeout
    case invalidResponse(String)
}

/// MCP 客户端:管理一个服务器连接(stdio / http)。
/// 实现 MCP 核心方法:initialize / tools/list / tools/call。
/// 采用 actor 隔离:Process 与管道句柄均为 actor 私有状态。
public actor MCPClient {
    public let config: MCPServerConfig
    private let timeout: Duration

    // stdio 传输状态
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutHandle: FileHandle?

    // 请求分发
    private var pending: [Int: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var nextID = 1
    private var lineBuffer = ""
    private var isConnected = false
    private var initialized = false

    public init(config: MCPServerConfig, timeout: Duration = .seconds(30)) {
        self.config = config
        self.timeout = timeout
    }

    deinit {
        process?.terminate()
    }

    // MARK: - 连接生命周期

    /// 建立连接(stdio:启动子进程;http:预留)
    public func connect() throws {
        guard !isConnected else { return }
        switch config.type {
        case "stdio", "":
            try connectStdio()
        case "http", "sse", "http/sse":
            throw MCPError.unsupportedTransport("http 传输将在后续版本支持,当前仅 stdio")
        default:
            throw MCPError.unsupportedTransport(config.type)
        }
        isConnected = true
    }

    private func connectStdio() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.command)
        process.arguments = config.args
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw MCPError.invalidResponse("无法启动 MCP 服务器 \(config.command): \(error.localizedDescription)")
        }
        self.process = process
        self.stdinPipe = inputPipe
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        // stdout 行读取:readabilityHandler 在后台队列回调,经 Task 跳转到本 actor
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { [weak self] in
                await self?.ingest(data)
            }
        }
    }

    public func disconnect() {
        stdoutHandle?.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutHandle = nil
        isConnected = false
        initialized = false
    }

    // MARK: - MCP 协议方法

    /// initialize + notifications/initialized 握手
    public func initialize() async throws -> AnyCodable? {
        try connect()
        let result = try await request(method: "initialize", params: .init([
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "ShizukuClaw", "version": ShizukuCore.version],
        ]))
        initialized = true
        // 通知(无响应)
        try? sendNotification(method: "notifications/initialized", params: nil)
        return result
    }

    /// 列出服务器工具
    public func listTools() async throws -> [MCPTool] {
        if !initialized {
            _ = try await initialize()
        }
        let result = try await request(method: "tools/list", params: .init([:]))
        guard let dict = result?.value as? [String: Any],
              let tools = dict["tools"] as? [[String: Any]]
        else {
            return []
        }
        return tools.compactMap { raw in
            guard let name = raw["name"] as? String else { return nil }
            return MCPTool(
                name: name,
                description: raw["description"] as? String,
                inputSchema: (raw["inputSchema"] ?? raw["input_schema"]).map { AnyCodable($0) }
            )
        }
    }

    /// 调用工具,返回文本内容
    public func callTool(name: String, arguments: [String: AnyCodable]) async throws -> String {
        if !initialized {
            _ = try await initialize()
        }
        let params: AnyCodable = .init([
            "name": name,
            "arguments": arguments.mapValues(\.value),
        ])
        let result = try await request(method: "tools/call", params: params)
        guard let dict = result?.value as? [String: Any] else {
            return "(空结果)"
        }
        if let isError = dict["isError"] as? Bool, isError {
            let content = Self.extractText(dict["content"])
            return "MCP 工具执行失败: \(content)"
        }
        return Self.extractText(dict["content"])
    }

    private static func extractText(_ content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "(空结果)" }
        return items.compactMap { item in
            if let text = item["text"] as? String {
                return text
            }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - 请求/响应

    /// 发送请求并等待响应(带超时)
    private func request(method: String, params: AnyCodable?) async throws -> AnyCodable? {
        try connect()
        let id = nextID
        nextID += 1
        let message = JSONRPCMessage.request(id: id, method: method, params: params)
        // 先同步发出请求;失败则不注册等待
        try send(message)

        return try await withThrowingTaskGroup(of: AnyCodable?.self) { group in
            group.addTask {
                try await self.awaitResponse(id: id)
            }
            group.addTask {
                try await Task.sleep(for: self.timeout)
                await self.failPending(id: id, error: MCPError.timeout)
                throw MCPError.timeout
            }
            guard let first = try await group.next() else {
                throw MCPError.invalidResponse("无响应")
            }
            group.cancelAll()
            return first
        }
    }

    private func awaitResponse(id: Int) async throws -> AnyCodable? {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    private func failPending(id: Int, error: Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func sendNotification(method: String, params: AnyCodable?) throws {
        try send(JSONRPCMessage(jsonrpc: "2.0", id: nil, method: method, params: params))
    }

    private func send(_ message: JSONRPCMessage) throws {
        guard let pipe = stdinPipe else {
            throw MCPError.notConnected
        }
        var data = try message.encode()
        data.append(0x0A)  // JSON-RPC over stdio 以换行分隔
        pipe.fileHandleForWriting.write(data)
    }

    /// 处理 stdout 数据:按行解析 JSON-RPC 并派发响应
    private func ingest(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        lineBuffer += chunk
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            dispatch(line: trimmed)
        }
    }

    private func dispatch(line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data)
        else { return }
        if let id = message.id, let continuation = pending.removeValue(forKey: id) {
            if let error = message.error {
                continuation.resume(throwing: MCPError.rpcError(error.code, error.message))
            } else {
                continuation.resume(returning: message.result)
            }
        }
        // 服务器主动推送(通知)暂不处理
    }
}
