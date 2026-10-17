import Foundation

/// 运行事件回放游标(纯展示,不重新执行工具/模型)。
public struct RunReplay: Sendable, Equatable {
    public let runID: String
    public let events: [RunEvent]
    public private(set) var cursor: Int

    public init(run: RunRecord, cursor: Int = 0) {
        self.runID = run.id
        self.events = run.events
        self.cursor = min(max(0, cursor), run.events.count)
    }

    public var total: Int { events.count }

    public var visibleEvents: [RunEvent] {
        Array(events.prefix(cursor))
    }

    public var current: RunEvent? {
        guard cursor > 0, cursor <= events.count else { return nil }
        return events[cursor - 1]
    }

    public var isFinished: Bool { cursor >= events.count }

    @discardableResult
    public mutating func step() -> RunEvent? {
        guard cursor < events.count else { return nil }
        cursor += 1
        return events[cursor - 1]
    }

    public mutating func reset() {
        cursor = 0
    }

    public mutating func jump(to index: Int) {
        cursor = min(max(0, index), events.count)
    }

    public mutating func toEnd() {
        cursor = events.count
    }
}
