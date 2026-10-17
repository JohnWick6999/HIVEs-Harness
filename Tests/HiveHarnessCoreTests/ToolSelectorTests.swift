import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("按问题选工具")
struct ToolSelectorTests {
    private func specs() -> [ToolSpec] {
        [
            ToolSpec(name: "read_file", description: "read"),
            ToolSpec(name: "write_file", description: "write"),
            ToolSpec(name: "http_get", description: "network"),
            ToolSpec(name: "run_local_agent", description: "cli"),
            ToolSpec(name: "create_plugin", description: "plugin"),
            ToolSpec(name: "run_subagent", description: "subagent"),
            ToolSpec(name: "ask_user", description: "ask"),
            ToolSpec(name: "todowrite", description: "plan"),
            ToolSpec(name: "mcp__demo__ping", description: "mcp"),
        ]
    }

    @Test("天气问题只暴露联网与基础工具")
    func weather() {
        let names = Set(ToolSelector.select(specs: specs(), query: "查一下营口天气", mode: .full).map(\.name))
        #expect(names.contains("http_get"))
        #expect(names.contains("read_file"))
        #expect(names.contains("ask_user"))
        #expect(!names.contains("run_local_agent"))
        #expect(!names.contains("create_plugin"))
    }

    @Test("插件/代码问题暴露对应工具")
    func pluginAndCode() {
        let plugin = Set(ToolSelector.select(specs: specs(), query: "帮我做一个插件", mode: .sandbox).map(\.name))
        #expect(plugin.contains("create_plugin"))
        #expect(!plugin.contains("http_get"))

        let code = Set(ToolSelector.select(specs: specs(), query: "审查代码并修复", mode: .full).map(\.name))
        #expect(code.contains("write_file"))
        #expect(code.contains("run_subagent"))
    }

    @Test("无关键词时回退到全部工具")
    func fallback() {
        let selected = ToolSelector.select(specs: specs(), query: "你好", mode: .full)
        #expect(selected.count == specs().count)
    }

    @Test("MCP 工具按问题启用")
    func mcp() {
        let selected = Set(ToolSelector.select(specs: specs(), query: "用 mcp 工具查一下", mode: .full).map(\.name))
        #expect(selected.contains("mcp__demo__ping"))
    }
}
