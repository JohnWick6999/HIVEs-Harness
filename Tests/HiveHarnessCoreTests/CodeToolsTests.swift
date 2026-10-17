import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("代码检索/编辑/Shell")
struct CodeToolsTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        try "let value = 1\nlet other = 2".write(
            to: url.appendingPathComponent("Sources/A.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "# 标题\nhello world".write(
            to: url.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        return url
    }

    @Test("glob 查找文件")
    func glob() throws {
        let root = try workspace()
        let tool = GlobTool(workspace: root)
        let result = try tool.run(arguments: ["pattern": AnyCodable("**/*.swift")])
        #expect(result.text.contains("Sources/A.swift"))
        #expect(!result.text.contains("README.md"))
    }

    @Test("grep 返回路径和行号")
    func grep() throws {
        let root = try workspace()
        let tool = GrepTool(workspace: root)
        let result = try tool.run(arguments: ["pattern": AnyCodable("value")])
        #expect(result.text.contains("Sources/A.swift:1"))
        #expect(result.text.contains("let value = 1"))
    }

    @Test("edit_file 精确替换并返回 diff")
    func edit() async throws {
        let root = try workspace()
        let tool = EditFileTool(workspace: root)
        let result = try await tool.run(arguments: [
            "path": AnyCodable("Sources/A.swift"),
            "old_string": AnyCodable("let value = 1"),
            "new_string": AnyCodable("let value = 10"),
        ])
        #expect(result.text.contains("已编辑"))
        #expect(result.changes.count == 1)
        let content = try String(contentsOf: root.appendingPathComponent("Sources/A.swift"))
        #expect(content.contains("let value = 10"))
    }

    @Test("shell 执行命令")
    func shell() async throws {
        let root = try workspace()
        let tool = ShellTool(workspace: root)
        let result = try await tool.run(arguments: [
            "command": AnyCodable("printf 'hello'"),
        ])
        #expect(result.text.contains("exit 0"))
        #expect(result.text.contains("hello"))
    }
}
