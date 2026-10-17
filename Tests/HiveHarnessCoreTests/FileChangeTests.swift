import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("代码变更 diff")
struct FileChangeTests {
    @Test("行级 diff 统计新增/删除")
    func lineDiff() {
        let diff = LineDiff.diff(
            old: "a\nb\nc",
            new: "a\nB\nc\nd"
        )
        #expect(diff.contains { $0.kind == .removed && $0.text == "b" })
        #expect(diff.contains { $0.kind == .added && $0.text == "B" })
        #expect(diff.contains { $0.kind == .added && $0.text == "d" })
        #expect(diff.contains { $0.kind == .context && $0.text == "a" })
    }

    @Test("WriteFileTool 返回前后快照")
    func writeSnapshot() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let tool = BuiltinTools.WriteFileTool(
            workspace: workspace,
            policy: FileAccessPolicy(mode: .sandbox)
        )
        _ = try await tool.run(arguments: [
            "path": AnyCodable("note.txt"),
            "content": AnyCodable("line 1\nline 2"),
        ])
        let result = try await tool.run(arguments: [
            "path": AnyCodable("note.txt"),
            "content": AnyCodable("line 1\nLINE 2\nline 3"),
        ])
        let change = try #require(result.changes.first)
        #expect(change.oldText == "line 1\nline 2")
        #expect(change.newText == "line 1\nLINE 2\nline 3")
        #expect(change.addedLines == 2)
        #expect(change.removedLines == 1)
    }
}
