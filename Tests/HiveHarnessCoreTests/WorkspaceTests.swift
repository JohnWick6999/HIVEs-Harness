import Foundation
@testable import HiveHarnessCore
import Testing

private func makeWorkspace() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hiveharness-workbench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("工作台")
struct WorkspaceTests {
    @Test("列目录 / 读文件 / 越界拒绝")
    func files() throws {
        let root = try makeWorkspace()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "nested".write(to: root.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

        let service = WorkspaceService(root: root)
        let entries = try service.list()
        #expect(entries.map(\.name) == ["sub", "a.txt"])
        #expect(entries.first?.isDirectory == true)
        #expect(try service.read(path: "a.txt") == "hello")
        #expect(try service.read(path: "sub/b.txt") == "nested")

        #expect(throws: WorkspaceError.self) {
            _ = try service.read(path: "../outside.txt")
        }
    }

    @Test("Shell 退出码与输出")
    func shell() throws {
        let service = WorkspaceService(root: try makeWorkspace())
        let echo = try service.runShell("echo hi")
        #expect(echo.exitCode == 0)
        #expect(echo.stdout.contains("hi"))

        let failed = try service.runShell("exit 3")
        #expect(failed.exitCode == 3)

        let timed = try service.runShell("sleep 3", timeout: 0.3)
        #expect(timed.timedOut)
    }

    @Test("Git status 读取")
    func gitStatus() throws {
        let root = try makeWorkspace()
        let service = WorkspaceService(root: root)
        _ = try service.runShell("git init -q")
        try "change".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let status = service.gitStatus()
        #expect(status.contains("?? new.txt") || status.contains("new.txt"))
    }
}
