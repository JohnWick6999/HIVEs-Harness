import Foundation

public enum RunStatus: String, Codable, Sendable, Equatable {
    case running
    case completed
    case failed
}

public enum RunEventKind: String, Codable, Sendable, Equatable {
    case started
    case model
    case tool
    case approval
    case question
    case answer
    case plan
    case context
    case finished
    case error
}

public struct RunEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var seq: Int
    public var kind: RunEventKind
    public var title: String
    public var detail: String
    public var timestamp: Date
    public var durationMs: Int?
    public var ok: Bool?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        seq: Int,
        kind: RunEventKind,
        title: String,
        detail: String = "",
        timestamp: Date = Date(),
        durationMs: Int? = nil,
        ok: Bool? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.seq = seq
        self.kind = kind
        self.title = title
        self.detail = detail
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.ok = ok
        self.metadata = metadata
    }
}

/// 一次 Agent 运行的可审计记录(本地保存,支持导出/回看)。
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var threadID: String
    public var persona: String
    public var status: RunStatus
    public var model: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var replyPreview: String
    public var promptTokens: Int
    public var completionTokens: Int
    public var events: [RunEvent]

    public init(
        id: String,
        threadID: String,
        persona: String,
        status: RunStatus,
        model: String = "",
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        replyPreview: String = "",
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        events: [RunEvent] = []
    ) {
        self.id = id
        self.threadID = threadID
        self.persona = persona
        self.status = status
        self.model = model
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.replyPreview = replyPreview
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.events = events
    }
}

/// 线程安全的事件收集器;由 AgentLoop 每轮创建。
public final class RunRecorder: @unchecked Sendable {
    public let id: String
    public let threadID: String
    public let persona: String
    public let startedAt = Date()

    private let lock = NSLock()
    private var events: [RunEvent] = []

    public init(id: String = UUID().uuidString, threadID: String, persona: String) {
        self.id = id
        self.threadID = threadID
        self.persona = persona
    }

    @discardableResult
    public func add(
        _ kind: RunEventKind,
        title: String,
        detail: String = "",
        durationMs: Int? = nil,
        ok: Bool? = nil,
        metadata: [String: String] = [:]
    ) -> RunEvent {
        lock.withLock {
            let event = RunEvent(
                seq: events.count + 1,
                kind: kind,
                title: title,
                detail: String(detail.prefix(4_000)),
                durationMs: durationMs,
                ok: ok,
                metadata: metadata
            )
            events.append(event)
            return event
        }
    }

    public func snapshot(
        status: RunStatus,
        model: String,
        replyPreview: String = "",
        promptTokens: Int = 0,
        completionTokens: Int = 0
    ) -> RunRecord {
        let snapshotEvents = lock.withLock { events }
        return RunRecord(
            id: id,
            threadID: threadID,
            persona: persona,
            status: status,
            model: model,
            startedAt: startedAt,
            finishedAt: status == .running ? nil : Date(),
            replyPreview: String(replyPreview.prefix(500)),
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            events: snapshotEvents
        )
    }
}
