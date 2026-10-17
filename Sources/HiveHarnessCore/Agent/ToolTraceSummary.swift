import Foundation

public struct ToolUsageSummary: Sendable, Equatable, Identifiable {
    public var name: String
    public var count: Int
    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public enum ToolTraceSummary {
    /// 按工具名聚合,保留首次出现顺序;同一工具多次调用只算一个工具。
    public static func grouped(_ traces: [ToolTrace]) -> [ToolUsageSummary] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for trace in traces {
            if counts[trace.tool] == nil { order.append(trace.tool) }
            counts[trace.tool, default: 0] += 1
        }
        return order.map { ToolUsageSummary(name: $0, count: counts[$0] ?? 0) }
    }
}
