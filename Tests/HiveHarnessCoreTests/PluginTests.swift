import Foundation
@testable import HiveHarnessCore
import Testing

func makePluginDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hiveharness-plugins-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func writePlugin(_ dir: URL, subdir: String, json: String) throws {
    let pluginDir = dir.appendingPathComponent(subdir)
    try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
    try json.write(to: pluginDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
}

@Suite("PluginManager")
struct PluginManagerTests {
    @Test("扫描插件清单并解析策略")
    func scan() throws {
        let dir = try makePluginDir()
        try writePlugin(dir, subdir: "hello", json: """
        {
          "name": "hello",
          "version": "1.2.0",
          "description": "打招呼插件",
          "author": "assistant",
          "hooks": ["chat"],
          "policy": {"enabled": true, "allow_network": true, "max_execution_ms": 5000}
        }
        """)

        let manager = PluginManager(pluginsDirectory: dir)
        let plugins = manager.listPlugins()
        #expect(plugins.count == 1)
        let hello = try #require(plugins.first)
        #expect(hello.id == "hello")
        #expect(hello.version == "1.2.0")
        #expect(hello.hooks == ["chat"])
        #expect(hello.policy.allowNetwork == true)
        #expect(hello.policy.maxExecutionMs == 5000)
        #expect(hello.policy.allowedDomains.isEmpty)
        #expect(hello.projectPath == "hello")
    }

    @Test("跳过 mcp/ 与 skills/ 目录")
    func skipDirectories() throws {
        let dir = try makePluginDir()
        try writePlugin(dir, subdir: "core", json: #"{"name":"core"}"#)
        try writePlugin(dir, subdir: "mcp/servers", json: #"{"name":"should-skip"}"#)
        try writePlugin(dir, subdir: "skills/extra", json: #"{"name":"also-skip"}"#)

        let manager = PluginManager(pluginsDirectory: dir)
        let ids = manager.listPlugins().map(\.id)
        #expect(ids == ["core"])
    }

    @Test("策略更新与开关")
    func policyUpdate() throws {
        let dir = try makePluginDir()
        try writePlugin(dir, subdir: "x", json: #"{"name":"x"}"#)
        let manager = PluginManager(pluginsDirectory: dir)

        var policy = PluginPolicy(allowNetwork: false)
        policy.allowedDomains = ["api.example.com"]
        try manager.updatePolicy(id: "x", policy: policy)
        #expect(manager.plugin(id: "x")?.policy.allowedDomains == ["api.example.com"])

        #expect(manager.isEnabled() == true)
        manager.setEnabled(false)
        #expect(manager.isEnabled() == false)

        let status = manager.frameworkStatus()
        #expect((status["loaded_plugins"] as? [String]) == ["x"])
    }

    @Test("更新不存在的插件抛错")
    func policyUnknown() {
        let dir = try! makePluginDir()
        let manager = PluginManager(pluginsDirectory: dir)
        #expect(throws: PluginError.notFound("nope")) {
            try manager.updatePolicy(id: "nope", policy: PluginPolicy())
        }
    }
}
