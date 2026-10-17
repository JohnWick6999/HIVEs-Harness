import Foundation

/// MCP 配置加载:支持 `servers.json` 容器格式与单服务器 `*.json`。
/// 与上游 `plugins/mcp/` 的字段保持一致。
public enum MCPConfigLoader {
    private struct ServersPayload: Codable {
        var servers: [MCPServerConfig]
    }

    public static func load(directory: URL) -> [MCPServerConfig] {
        var result: [MCPServerConfig] = []
        var seen = Set<String>()

        let serversURL = directory.appendingPathComponent("servers.json")
        if let data = try? Data(contentsOf: serversURL) {
            if let payload = try? JSONDecoder().decode(ServersPayload.self, from: data) {
                for var config in payload.servers {
                    if config.name.isEmpty { config.name = config.id }
                    if seen.insert(config.id).inserted { result.append(config) }
                }
            } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let servers = object["mcpServers"] as? [String: Any] {
                // Claude / VS Code 兼容:{"mcpServers": {"name": {...}}}
                for (key, value) in servers.sorted(by: { $0.key < $1.key }) {
                    guard let dict = value as? [String: Any],
                          let valueData = try? JSONSerialization.data(withJSONObject: dict),
                          var config = try? JSONDecoder().decode(MCPServerConfig.self, from: valueData)
                    else { continue }
                    config.id = key
                    if config.name.isEmpty { config.name = key }
                    if config.command.isEmpty && !config.url.isEmpty {
                        config.type = "http"
                    }
                    if let disabled = dict["disabled"] as? Bool {
                        config.enabled = !disabled
                    }
                    if seen.insert(config.id).inserted { result.append(config) }
                }
            }
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "json" && file.lastPathComponent != "servers.json" {
            guard let data = try? Data(contentsOf: file),
                  var config = try? JSONDecoder().decode(MCPServerConfig.self, from: data)
            else { continue }
            // 单文件未写 id 时用文件名(兼容上游 *.json 约定)
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if raw?["id"] == nil || (raw?["id"] as? String)?.isEmpty == true {
                config.id = file.deletingPathExtension().lastPathComponent
                if config.name.isEmpty { config.name = config.id }
            }
            if seen.insert(config.id).inserted { result.append(config) }
        }
        return result
    }

    public static func save(_ configs: [MCPServerConfig], directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = ServersPayload(servers: configs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(
            to: directory.appendingPathComponent("servers.json"),
            options: .atomic
        )
    }
}
