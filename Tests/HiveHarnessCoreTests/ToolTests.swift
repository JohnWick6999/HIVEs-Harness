import Foundation
@testable import HiveHarnessCore
import Testing

func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hiveharness-ws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("SafePath 沙箱")
struct SafePathTests {
    @Test("正常相对路径解析")
    func resolveNormal() throws {
        let ws = try tempDir()
        let safe = SafePath(workspace: ws)
        #expect(try safe.resolve("a/b.txt").path == ws.appendingPathComponent("a/b.txt").standardizedFileURL.path)
        #expect(try safe.resolve("/etc/passwd").path.hasPrefix(ws.path))
    }

    @Test("拒绝目录逃逸")
    func rejectEscape() {
        let ws = try! tempDir()
        let safe = SafePath(workspace: ws)
        #expect(throws: ToolError.pathEscape("../../etc/passwd")) {
            _ = try safe.resolve("../../etc/passwd")
        }
        // 绝对路径按设计被 lstrip 相对化(对齐原版),解析结果仍在工作区内
        let absolutized = try? safe.resolve("/Users")
        #expect(absolutized?.path.hasPrefix(ws.path) == true)
    }
}

@Suite("ToolRegistry")
struct ToolRegistryTests {
    struct EchoTool: Tool {
        let name = "echo"
        let spec = ToolSpec(name: "echo", description: "echo")
        func run(arguments: [String: AnyCodable]) throws -> ToolResult {
            ToolResult(text: (arguments["text"]?.value as? String) ?? "")
        }
    }

    @Test("注册与执行")
    func registerAndExecute() async throws {
        let registry = ToolRegistry()
        registry.register(EchoTool())
        #expect(try await registry.execute(name: "echo", arguments: ["text": AnyCodable("hi")]).text == "hi")
        #expect(registry.names() == ["echo"])
        #expect(registry.specs().count == 1)
    }

    @Test("未知工具抛出 notFound(原版 bug 回归测试)")
    func unknownToolThrows() async {
        let registry = ToolRegistry()
        // 原版:工具存在时抛 ValueError、不存在时抛 KeyError(逻辑写反)
        // 正确语义:不存在 -> notFound
        await #expect(throws: ToolError.notFound("nope")) {
            _ = try await registry.execute(name: "nope", arguments: [:])
        }
    }
}

@Suite("内置文件工具")
struct BuiltinFileToolsTests {
    @Test("list_dir 列出内容并标记图片")
    func listDir() async throws {
        let ws = try tempDir()
        try FileManager.default.createDirectory(at: ws.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello".write(to: ws.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50]).write(to: ws.appendingPathComponent("img.png"))

        let tool = BuiltinTools.ListDirTool(workspace: ws)
        let output = try await tool.run(arguments: [:]).text
        #expect(output.contains("a.txt"))
        #expect(output.contains("sub/"))
        #expect(output.contains("img.png [image, skip]"))
    }

    @Test("read_file 文本/缺失/图片提示")
    func readFile() async throws {
        let ws = try tempDir()
        try String(repeating: "长", count: 15_000).write(to: ws.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: ws.appendingPathComponent("pic.png"))

        let tool = BuiltinTools.ReadFileTool(workspace: ws)
        let big = try await tool.run(arguments: ["path": AnyCodable("big.txt")]).text
        #expect(big.hasSuffix("...[truncated]"))

        let image = try await tool.run(arguments: ["path": AnyCodable("pic.png")]).text
        #expect(image.contains("图片文件"))

        let missing = try await tool.run(arguments: ["path": AnyCodable("nope.txt")]).text
        #expect(missing.contains("文件不存在"))
    }

    @Test("write_file 写入并可读回")
    func writeFile() async throws {
        let ws = try tempDir()
        let tool = BuiltinTools.WriteFileTool(workspace: ws)
        let result = try await tool.run(arguments: [
            "path": AnyCodable("notes/hello.txt"),
            "content": AnyCodable("你好 HIVE"),
        ])
        let output = result.text
        #expect(result.files.count == 1)
        #expect(result.files.first?.lastPathComponent == "hello.txt")
        #expect(output.contains("已写入"))
        let read = try String(contentsOf: ws.appendingPathComponent("notes/hello.txt"), encoding: .utf8)
        #expect(read == "你好 HIVE")
    }
}

@Suite("内置记忆工具")
struct BuiltinMemoryToolsTests {
    @Test("search/add 记忆联动")
    func memoryTools() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hiveharness-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: dir.appendingPathComponent("agent.db").path)

        let add = BuiltinTools.AddMemoryTool(store: store, persona: "assistant")
        #expect(try await add.run(arguments: ["content": AnyCodable("用户喜欢 R&B")]).text.contains("已写入"))

        let search = BuiltinTools.SearchMemoryTool(store: store, persona: "assistant")
        let result = try await search.run(arguments: ["query": AnyCodable("R&B")]).text
        #expect(result.contains("R&B"))

        let empty = try await search.run(arguments: ["query": AnyCodable("不存在的关键词xyz")]).text
        #expect(empty.contains("没有找到"))
    }
}

#if os(macOS)
@Suite("RunLocalAgentTool")
struct RunLocalAgentToolTests {
    @Test("注入 /bin/echo 验证进程调用")
    func runEcho() async throws {
        let tool = BuiltinTools.RunLocalAgentTool(
            agentCommands: ["echo": "/bin/echo"],
            timeout: 10
        )
        let output = try await tool.run(arguments: [
            "agent": AnyCodable("echo"),
            "prompt": AnyCodable("hello from assistant"),
        ]).text
        #expect(output == "hello from assistant")
    }

    @Test("未知 agent 返回提示")
    func unknownAgent() async throws {
        let tool = BuiltinTools.RunLocalAgentTool(agentCommands: ["echo": "/bin/echo"])
        let output = try await tool.run(arguments: [
            "agent": AnyCodable("nope"),
            "prompt": AnyCodable("x"),
        ]).text
        #expect(output.contains("未知 Agent"))
    }
}
#endif
