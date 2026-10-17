import Foundation
import SQLite3

public enum StorageError: Error, Sendable, Equatable {
    case openFailed(String)
    case sqlite(String)
    case encode(String)
}

/// 绑定到 SQLite 语句的值类型
enum SQLiteValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

/// SQLite 存储层:零外部依赖,直接封装系统 libsqlite3。
/// 四张表对齐原版(SQLite/MySQL/PG 多驱动精简为 SQLite——Apple 平台单机场景)。
///
/// 线程安全:内部 NSLock 串行化(对应原版 threading.RLock 的设计),
/// 通过 @unchecked Sendable 跨 actor 传递(所有可变状态均在锁内访问)。
public final class SQLiteStore: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    public let path: String

    // MARK: - 生命周期

    public init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let rc = sqlite3_open(path, &handle)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            throw StorageError.openFailed(message)
        }
        db = handle
        lock.lock()
        defer { lock.unlock() }
        try execLocked("PRAGMA journal_mode=WAL")
        try execLocked("PRAGMA foreign_keys=ON")
        try migrateLocked()
    }

    deinit {
        // 应用生命周期内单例持有;进程退出时系统回收
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema

    private func migrateLocked() throws {
        try execLocked("""
            CREATE TABLE IF NOT EXISTS chat_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                persona TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS memories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                persona TEXT NOT NULL,
                kind TEXT NOT NULL,
                content TEXT NOT NULL,
                metadata TEXT,
                embedding TEXT,
                created_at TEXT NOT NULL,
                source_thread TEXT,
                source_kind TEXT NOT NULL DEFAULT 'manual',
                confidence REAL NOT NULL DEFAULT 0.6,
                use_count INTEGER NOT NULL DEFAULT 0,
                last_used_at TEXT
            );
            CREATE TABLE IF NOT EXISTS checkpoints (
                thread_id TEXT NOT NULL,
                persona TEXT NOT NULL,
                state_json TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (thread_id, persona)
            );
            CREATE TABLE IF NOT EXISTS kv_store (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS task_plans (
                thread_id TEXT NOT NULL,
                persona TEXT NOT NULL,
                plan_json TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (thread_id, persona)
            );
            CREATE TABLE IF NOT EXISTS session_context (
                thread_id TEXT NOT NULL,
                persona TEXT NOT NULL,
                state_json TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (thread_id, persona)
            );
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT NOT NULL,
                persona TEXT NOT NULL,
                title TEXT NOT NULL,
                preview TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (id, persona)
            );
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL,
                persona TEXT NOT NULL,
                status TEXT NOT NULL,
                model TEXT NOT NULL,
                started_at TEXT NOT NULL,
                finished_at TEXT,
                record_json TEXT NOT NULL
            );
            """)

        // 旧库没有 thread_id:补列以便按会话清理聊天记录
        let columns = try queryLocked("PRAGMA table_info(chat_records)")
        if !columns.contains(where: { textValue($0["name"] ?? "") == "thread_id" }) {
            try execLocked("ALTER TABLE chat_records ADD COLUMN thread_id TEXT")
        }

        // 旧库补齐记忆溯源字段
        let memoryColumns = try queryLocked("PRAGMA table_info(memories)")
        let memoryNames = Set(memoryColumns.map { textValue($0["name"] ?? "") })
        let additions: [(String, String)] = [
            ("source_thread", "TEXT"),
            ("source_kind", "TEXT NOT NULL DEFAULT 'manual'"),
            ("confidence", "REAL NOT NULL DEFAULT 0.6"),
            ("use_count", "INTEGER NOT NULL DEFAULT 0"),
            ("last_used_at", "TEXT"),
        ]
        for (name, definition) in additions where !memoryNames.contains(name) {
            try execLocked("ALTER TABLE memories ADD COLUMN \(name) \(definition)")
        }
    }

    // MARK: - 底层执行

    private func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func lastErrorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func execLocked(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errorMessage)
            throw StorageError.sqlite(message)
        }
    }

    private func bind(_ statement: OpaquePointer, _ values: [SQLiteValue]) throws {
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .integer(let n): sqlite3_bind_int64(statement, index, n)
            case .real(let d): sqlite3_bind_double(statement, index, d)
            case .text(let s):
                sqlite3_bind_text(statement, index, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(statement, index)
            }
        }
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        let rc = sqlite3_step(statement)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StorageError.sqlite(lastErrorMessage())
        }
    }

    /// 执行查询,返回列名 -> 值(Int64/Double/String)
    private func queryLocked(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StorageError.sqlite(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, values)

        var rows: [[String: Any]] = []
        while try step(statement) {
            var row: [String: Any] = [:]
            let count = sqlite3_column_count(statement)
            for i in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(statement, i))
                default:
                    row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func executeLocked(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StorageError.sqlite(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, values)
        _ = try step(statement)
        return sqlite3_last_insert_rowid(db)
    }

    private func intValue(_ value: Any) -> Int64 {
        (value as? Int64) ?? 0
    }

    private func textValue(_ value: Any) -> String {
        (value as? String) ?? ""
    }

    // MARK: - 聊天记录

    public func addChatRecord(
        persona: String,
        role: String,
        content: String,
        threadID: String? = nil
    ) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return try executeLocked(
            "INSERT INTO chat_records(persona, role, content, created_at, thread_id) VALUES (?, ?, ?, ?, ?)",
            [.text(persona), .text(role), .text(content), .text(now()), .text(threadID ?? "")]
        )
    }

    public func listChatRecords(limit: Int = 200, offset: Int = 0) throws -> [ChatRecord] {
        lock.lock()
        defer { lock.unlock() }
        let rows = try queryLocked(
            "SELECT id, persona, role, content, created_at FROM chat_records ORDER BY id DESC LIMIT ? OFFSET ?",
            [.integer(Int64(limit)), .integer(Int64(offset))]
        )
        return rows.map { row in
            ChatRecord(
                id: intValue(row["id"] ?? 0),
                persona: textValue(row["persona"] ?? ""),
                role: textValue(row["role"] ?? ""),
                content: textValue(row["content"] ?? ""),
                createdAt: textValue(row["created_at"] ?? "")
            )
        }
    }

    /// 按会话读取聊天记录(用于会话删除校验/记录页)。
    public func listChatRecords(
        threadID: String,
        persona: String? = nil,
        limit: Int = 200
    ) throws -> [ChatRecord] {
        lock.lock()
        defer { lock.unlock() }
        var sql = "SELECT id, persona, role, content, created_at FROM chat_records WHERE thread_id = ?"
        var values: [SQLiteValue] = [.text(threadID)]
        if let persona {
            sql += " AND persona = ?"
            values.append(.text(persona))
        }
        sql += " ORDER BY id DESC LIMIT ?"
        values.append(.integer(Int64(limit)))
        let rows = try queryLocked(sql, values)
        return rows.map { row in
            ChatRecord(
                id: intValue(row["id"] ?? 0),
                persona: textValue(row["persona"] ?? ""),
                role: textValue(row["role"] ?? ""),
                content: textValue(row["content"] ?? ""),
                createdAt: textValue(row["created_at"] ?? "")
            )
        }
    }

    @discardableResult
    public func deleteChatRecord(id: Int64) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM chat_records WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw StorageError.sqlite(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, [.integer(id)])
        _ = try step(statement)
        return sqlite3_changes(db) > 0
    }

    public func clearChatRecords() throws {
        lock.lock()
        defer { lock.unlock() }
        try execLocked("DELETE FROM chat_records")
    }

    public func deleteFirstN(_ n: Int) throws -> Int {
        let records = try listChatRecords(limit: n, offset: 0)
        var deleted = 0
        for record in records where try deleteChatRecord(id: record.id) {
            deleted += 1
        }
        return deleted
    }

    // MARK: - 记忆

    public func addMemory(
        persona: String,
        content: String,
        kind: String = "long_term",
        metadata: [String: AnyCodable]? = nil,
        sourceThread: String? = nil,
        sourceKind: String = "manual",
        confidence: Double = 0.6
    ) throws -> Int64 {
        let embedding = TextEmbedding.hashVector(content)
        let embeddingJSON = try encodeJSON(embedding)
        let metadataJSON = try encodeJSON(metadata ?? [:])
        lock.lock()
        defer { lock.unlock() }
        return try executeLocked(
            """
            INSERT INTO memories(
                persona, kind, content, metadata, embedding, created_at,
                source_thread, source_kind, confidence, use_count, last_used_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL)
            """,
            [
                .text(persona),
                .text(kind),
                .text(content),
                .text(metadataJSON),
                .text(embeddingJSON),
                .text(now()),
                .text(sourceThread ?? ""),
                .text(sourceKind),
                .real(confidence),
            ]
        )
    }

    public func listMemories(persona: String? = nil, kind: String? = nil, limit: Int = 50) throws -> [MemoryItem] {
        lock.lock()
        defer { lock.unlock() }
        var sql = "SELECT id, persona, kind, content, metadata, created_at, source_thread, source_kind, confidence, use_count, last_used_at FROM memories"
        var values: [SQLiteValue] = []
        var conditions: [String] = []
        if let persona {
            conditions.append("persona = ?")
            values.append(.text(persona))
        }
        if let kind {
            conditions.append("kind = ?")
            values.append(.text(kind))
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY id DESC LIMIT ?"
        values.append(.integer(Int64(limit)))

        let rows = try queryLocked(sql, values)
        return rows.map { row in
            MemoryItem(
                id: intValue(row["id"] ?? 0),
                persona: textValue(row["persona"] ?? ""),
                kind: textValue(row["kind"] ?? ""),
                content: textValue(row["content"] ?? ""),
                metadata: decodeJSONDict(textValue(row["metadata"] ?? "{}")),
                createdAt: textValue(row["created_at"] ?? ""),
                sourceThread: textValue(row["source_thread"] ?? "").isEmpty ? nil : textValue(row["source_thread"] ?? ""),
                sourceKind: textValue(row["source_kind"] ?? "manual"),
                confidence: (row["confidence"] as? Double) ?? 0.6,
                useCount: Int(intValue(row["use_count"] ?? 0)),
                lastUsedAt: textValue(row["last_used_at"] ?? "").isEmpty ? nil : textValue(row["last_used_at"] ?? "")
            )
        }
    }

    /// 删除单条记忆(记忆管理页用)
    @discardableResult
    public func deleteMemory(id: Int64) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM memories WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw StorageError.sqlite(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement, [.integer(id)])
        _ = try step(statement)
        return sqlite3_changes(db) > 0
    }

    /// 余弦相似度检索(原版 search_memories)
    public func searchMemories(query: String, persona: String? = nil, topK: Int = 5) throws -> [MemoryItem] {
        let queryVector = TextEmbedding.hashVector(query)
        lock.lock()
        defer { lock.unlock() }
        var sql = "SELECT id, persona, kind, content, metadata, embedding, created_at, source_thread, source_kind, confidence, use_count, last_used_at FROM memories"
        var values: [SQLiteValue] = []
        if let persona {
            sql += " WHERE persona = ?"
            values.append(.text(persona))
        }
        let rows = try queryLocked(sql, values)
        let scored = rows.compactMap { row -> MemoryItem? in
            let content = textValue(row["content"] ?? "")
            // 共享字符过滤:无任何重叠字符视为不相关(哈希向量碰撞噪声大,不能只靠余弦阈值)
            guard TextEmbedding.hasSharedCharacters(query, content) else { return nil }
            let raw = textValue(row["embedding"] ?? "")
            guard let stored = decodeJSONArray(raw) else { return nil }
            let score = TextEmbedding.cosine(queryVector, stored)
            return MemoryItem(
                id: intValue(row["id"] ?? 0),
                persona: textValue(row["persona"] ?? ""),
                kind: textValue(row["kind"] ?? ""),
                content: textValue(row["content"] ?? ""),
                metadata: decodeJSONDict(textValue(row["metadata"] ?? "{}")),
                score: score,
                createdAt: textValue(row["created_at"] ?? ""),
                sourceThread: textValue(row["source_thread"] ?? "").isEmpty ? nil : textValue(row["source_thread"] ?? ""),
                sourceKind: textValue(row["source_kind"] ?? "manual"),
                confidence: (row["confidence"] as? Double) ?? 0.6,
                useCount: Int(intValue(row["use_count"] ?? 0)),
                lastUsedAt: textValue(row["last_used_at"] ?? "").isEmpty ? nil : textValue(row["last_used_at"] ?? "")
            )
        }
        let result = scored.sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(topK).map { $0 }
        let timestamp = now()
        for item in result {
            _ = try? executeLocked(
                "UPDATE memories SET use_count = use_count + 1, last_used_at = ? WHERE id = ?",
                [.text(timestamp), .integer(item.id)]
            )
        }
        return result
    }

    // MARK: - 检查点

    public func saveCheckpoint(threadID: String, persona: String, state: [String: AnyCodable]) throws {
        let json = try encodeJSON(state)
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            """
            INSERT INTO checkpoints(thread_id, persona, state_json, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(thread_id, persona) DO UPDATE SET
                state_json=excluded.state_json,
                updated_at=excluded.updated_at
            """,
            [.text(threadID), .text(persona), .text(json), .text(now())]
        )
    }

    public func loadCheckpoint(threadID: String, persona: String) throws -> [String: AnyCodable]? {
        lock.lock()
        defer { lock.unlock() }
        let rows = try queryLocked(
            "SELECT state_json FROM checkpoints WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
        guard let row = rows.first else { return nil }
        return decodeJSONDict(textValue(row["state_json"] ?? "{}"))
    }

    /// 保存会话消息历史(对话检查点,对齐原版 checkpoint 最近 40 条)
    public func saveMessages(threadID: String, persona: String, messages: [ChatMessage]) throws {
        let data = try JSONEncoder().encode(messages)
        guard let json = String(data: data, encoding: .utf8) else {
            throw StorageError.encode("消息编码失败")
        }
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            """
            INSERT INTO checkpoints(thread_id, persona, state_json, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(thread_id, persona) DO UPDATE SET
                state_json=excluded.state_json,
                updated_at=excluded.updated_at
            """,
            [.text(threadID), .text(persona), .text(json), .text(now())]
        )
    }

    public func loadMessages(threadID: String, persona: String) throws -> [ChatMessage]? {
        lock.lock()
        defer { lock.unlock() }
        let rows = try queryLocked(
            "SELECT state_json FROM checkpoints WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
        guard let row = rows.first,
              let data = textValue(row["state_json"] ?? "").data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode([ChatMessage].self, from: data)
    }

    // MARK: - KV

    public func setKV(key: String, value: AnyCodable) throws {
        let json = try encodeJSON(value)
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            """
            INSERT INTO kv_store(key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
            """,
            [.text(key), .text(json), .text(now())]
        )
    }

    public func getKV(key: String) throws -> AnyCodable? {
        lock.lock()
        defer { lock.unlock() }
        let rows = try queryLocked("SELECT value FROM kv_store WHERE key = ?", [.text(key)])
        guard let row = rows.first else { return nil }
        let raw = textValue(row["value"] ?? "")
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnyCodable.self, from: data)
    }

    // MARK: - 任务计划

    public func saveTaskPlan(_ plan: TaskPlan, threadID: String, persona: String) throws {
        let json = try encodeJSON(plan)
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            """
            INSERT INTO task_plans(thread_id, persona, plan_json, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(thread_id, persona) DO UPDATE SET
                plan_json=excluded.plan_json,
                updated_at=excluded.updated_at
            """,
            [.text(threadID), .text(persona), .text(json), .text(now())]
        )
    }

    /// 读取任务计划;不存在时返回空计划(不创建行)。
    public func loadTaskPlan(threadID: String, persona: String) throws -> TaskPlan {
        lock.lock()
        defer { lock.unlock() }
        let rows = try queryLocked(
            "SELECT plan_json FROM task_plans WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
        guard let row = rows.first,
              let data = textValue(row["plan_json"] ?? "").data(using: .utf8),
              let plan = try? JSONDecoder().decode(TaskPlan.self, from: data)
        else { return .empty }
        return plan
    }

    public func deleteTaskPlan(threadID: String, persona: String) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            "DELETE FROM task_plans WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
    }

    // MARK: - 上下文状态

    public func saveContextState(
        _ state: SessionContextState,
        threadID: String,
        persona: String
    ) throws {
        let json = try encodeJSON(state)
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            """
            INSERT INTO session_context(thread_id, persona, state_json, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(thread_id, persona) DO UPDATE SET
                state_json=excluded.state_json,
                updated_at=excluded.updated_at
            """,
            [.text(threadID), .text(persona), .text(json), .text(now())]
        )
    }

    public func loadContextState(threadID: String, persona: String) throws -> SessionContextState {
        lock.lock()
        defer { lock.unlock() }
        let rows = try queryLocked(
            "SELECT state_json FROM session_context WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
        guard let row = rows.first,
              let data = textValue(row["state_json"] ?? "").data(using: .utf8),
              let state = try? JSONDecoder().decode(SessionContextState.self, from: data)
        else { return .empty }
        return state
    }

    public func deleteContextState(threadID: String, persona: String) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            "DELETE FROM session_context WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
    }

    // MARK: - 会话索引

    public func upsertSession(_ session: SessionRecord) throws {
        let created = ISO8601DateFormatter().string(from: session.createdAt)
        let updated = ISO8601DateFormatter().string(from: session.updatedAt)
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            """
            INSERT INTO sessions(id, persona, title, preview, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id, persona) DO UPDATE SET
                title=excluded.title,
                preview=excluded.preview,
                updated_at=excluded.updated_at
            """,
            [
                .text(session.id),
                .text(session.persona),
                .text(session.title),
                .text(session.preview),
                .text(created),
                .text(updated),
            ]
        )
    }

    public func listSessions(persona: String) throws -> [SessionRecord] {
        lock.lock()
        defer { lock.unlock() }
        let rows = try queryLocked(
            """
            SELECT id, persona, title, preview, created_at, updated_at
            FROM sessions WHERE persona = ? ORDER BY updated_at DESC
            """,
            [.text(persona)]
        )
        let formatter = ISO8601DateFormatter()
        return rows.map { row in
            SessionRecord(
                id: textValue(row["id"] ?? ""),
                persona: textValue(row["persona"] ?? ""),
                title: textValue(row["title"] ?? ""),
                preview: textValue(row["preview"] ?? ""),
                createdAt: formatter.date(from: textValue(row["created_at"] ?? "")) ?? Date(),
                updatedAt: formatter.date(from: textValue(row["updated_at"] ?? "")) ?? Date()
            )
        }
    }

    /// 删除会话及其 checkpoint、任务计划、上下文状态与聊天记录。
    public func deleteSession(threadID: String, persona: String) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            "DELETE FROM sessions WHERE id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
        _ = try executeLocked(
            "DELETE FROM checkpoints WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
        _ = try executeLocked(
            "DELETE FROM task_plans WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
        _ = try executeLocked(
            "DELETE FROM session_context WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
        _ = try executeLocked(
            "DELETE FROM chat_records WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
        _ = try executeLocked(
            "DELETE FROM runs WHERE thread_id = ? AND persona = ?",
            [.text(threadID), .text(persona)]
        )
    }

    // MARK: - 运行日志

    public func saveRun(_ run: RunRecord) throws {
        let json = try encodeJSON(run)
        let formatter = ISO8601DateFormatter()
        let started = formatter.string(from: run.startedAt)
        let finished = run.finishedAt.map { formatter.string(from: $0) }
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked(
            """
            INSERT INTO runs(id, thread_id, persona, status, model, started_at, finished_at, record_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status=excluded.status,
                finished_at=excluded.finished_at,
                record_json=excluded.record_json
            """,
            [
                .text(run.id),
                .text(run.threadID),
                .text(run.persona),
                .text(run.status.rawValue),
                .text(run.model),
                .text(started),
                finished.map { SQLiteValue.text($0) } ?? .null,
                .text(json),
            ]
        )
    }

    public func listRuns(persona: String, limit: Int = 50) throws -> [RunRecord] {
        try listRuns(
            query: "SELECT record_json FROM runs WHERE persona = ? ORDER BY started_at DESC LIMIT ?",
            values: [.text(persona), .integer(Int64(limit))]
        )
    }

    public func listRuns(threadID: String, persona: String, limit: Int = 50) throws -> [RunRecord] {
        try listRuns(
            query: """
            SELECT record_json FROM runs
            WHERE thread_id = ? AND persona = ?
            ORDER BY started_at DESC LIMIT ?
            """,
            values: [.text(threadID), .text(persona), .integer(Int64(limit))]
        )
    }

    private func listRuns(query: String, values: [SQLiteValue]) throws -> [RunRecord] {
        lock.lock()
        defer { lock.unlock() }
        let rows = try queryLocked(query, values)
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            guard let data = textValue(row["record_json"] ?? "").data(using: .utf8) else {
                return nil
            }
            return try? decoder.decode(RunRecord.self, from: data)
        }
    }

    public func loadRun(id: String) throws -> RunRecord? {
        lock.lock()
        defer { lock.unlock() }
        let rows = try queryLocked(
            "SELECT record_json FROM runs WHERE id = ?",
            [.text(id)]
        )
        guard let row = rows.first,
              let data = textValue(row["record_json"] ?? "").data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(RunRecord.self, from: data)
    }

    public func deleteRun(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try executeLocked("DELETE FROM runs WHERE id = ?", [.text(id)])
    }

    // MARK: - 状态

    public func status() -> [String: String] {
        ["driver": "sqlite", "path": path]
    }

    // MARK: - JSON 辅助

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw StorageError.encode("JSON 编码失败")
        }
        return string
    }

    private func decodeJSONArray(_ raw: String) -> [Double]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Double].self, from: data)
    }

    private func decodeJSONDict(_ raw: String) -> [String: AnyCodable]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: AnyCodable].self, from: data)
    }
}
