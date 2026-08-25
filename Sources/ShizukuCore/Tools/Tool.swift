import Foundation

public enum ToolError: Error, Sendable, Equatable {
    /// 工具不存在
    case notFound(String)
    /// 参数错误
    case invalidArguments(String)
    /// 路径逃逸工作区沙箱
    case pathEscape(String)
    /// 执行失败
    case execution(String)
}

/// Agent 工具协议。实现必须为 Sendable(纯函数或持有不可变依赖)。
public protocol Tool: Sendable {
    /// 工具名称,作为模型调用标识
    var name: String { get }
    /// 供模型识别的完整描述(名称/说明/JSON Schema 参数)
    var spec: ToolSpec { get }
    /// 执行工具;arguments 为 JSON 解析后的参数
    func run(arguments: [String: AnyCodable]) throws -> String
}

/// 工具注册表(对应原版 ToolRegistry)。
/// 注意:原版此处有反转 bug(存在时抛错),本实现为正确语义:
/// 工具不存在时抛出 notFound。
public final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: any Tool] = [:]

    public init() {}

    public func register(_ tool: any Tool) {
        lock.lock()
        defer { lock.unlock() }
        tools[tool.name] = tool
    }

    public func execute(name: String, arguments: [String: AnyCodable]) throws -> String {
        lock.lock()
        let tool = tools[name]
        lock.unlock()
        guard let tool else {
            throw ToolError.notFound(name)
        }
        return try tool.run(arguments: arguments)
    }

    /// 全部工具的模型侧描述(用于 tools 参数)
    public func specs() -> [ToolSpec] {
        lock.lock()
        let values = Array(tools.values)
        lock.unlock()
        return values.map(\.spec)
    }

    public func names() -> [String] {
        lock.lock()
        let keys = Array(tools.keys)
        lock.unlock()
        return keys.sorted()
    }
}
