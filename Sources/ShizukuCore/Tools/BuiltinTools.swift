import Foundation

/// 内置工具集,功能对齐原版 `app/agent/tools.py`:
/// list_dir / read_file / write_file / search_memory / add_memory / run_local_agent
public enum BuiltinTools {
    static let imageSuffixes: Set<String> = [
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".tif", ".tiff",
    ]

    // MARK: - 目录

    public struct ListDirTool: Tool {
        public let name = "list_dir"
        public let spec = ToolSpec(
            name: "list_dir",
            description: "List files in the local workspace. Directories end with '/', images are marked [image, skip].",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "path": ["type": "string", "description": "Relative workspace path"]
                ]),
            ]
        )
        private let safePath: SafePath

        public init(workspace: URL) {
            self.safePath = SafePath(workspace: workspace)
        }

        public func run(arguments: [String: AnyCodable]) throws -> String {
            let raw = arguments["path"]?.value as? String ?? "."
            let target = try safePath.resolve(raw)
            guard FileManager.default.fileExists(atPath: target.path) else {
                return "目录不存在: \(raw)"
            }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
            guard isDirectory.boolValue else {
                return "不是目录: \(raw)"
            }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
            let lines = items.sorted().map { item in
                let full = target.appendingPathComponent(item)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full.path, isDirectory: &isDir)
                if isDir.boolValue {
                    return "\(item)/"
                }
                if imageSuffixes.contains(full.pathExtension.lowercased().isEmpty ? "" : ".\(full.pathExtension.lowercased())") {
                    return "\(item) [image, skip]"
                }
                return item
            }
            return lines.isEmpty ? "(空目录)" : lines.joined(separator: "\n")
        }
    }

    // MARK: - 读文件

    public struct ReadFileTool: Tool {
        public let name = "read_file"
        public let spec = ToolSpec(
            name: "read_file",
            description: "Read a workspace text file. Do not use this on png/jpg/gif/webp images.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["path": ["type": "string"]]),
                "required": AnyCodable(["path"]),
            ]
        )
        private let safePath: SafePath
        public let maxChars: Int

        public init(workspace: URL, maxChars: Int = 12_000) {
            self.safePath = SafePath(workspace: workspace)
            self.maxChars = maxChars
        }

        public func run(arguments: [String: AnyCodable]) throws -> String {
            guard let raw = arguments["path"]?.value as? String else {
                throw ToolError.invalidArguments("缺少 path 参数")
            }
            let target = try safePath.resolve(raw)
            guard FileManager.default.fileExists(atPath: target.path) else {
                return "文件不存在: \(raw)"
            }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else {
                return "不是文件: \(raw)"
            }
            if imageSuffixes.contains(".\(target.pathExtension.lowercased())") {
                return "\(target.lastPathComponent) 是图片文件。当前主模型不能看图,不要再调用 read_file 读取图片,请让用户用文字描述内容。"
            }
            guard let data = FileManager.default.contents(atPath: target.path) else {
                return "读取失败: \(raw)"
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return "\(target.lastPathComponent) 是二进制文件,已跳过。"
            }
            if text.count > maxChars {
                return String(text.prefix(maxChars)) + "\n...[truncated]"
            }
            return text
        }
    }

    // MARK: - 写文件

    public struct WriteFileTool: Tool {
        public let name = "write_file"
        public let spec = ToolSpec(
            name: "write_file",
            description: "Write a text file in the workspace.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "path": ["type": "string"],
                    "content": ["type": "string"],
                ]),
                "required": AnyCodable(["path", "content"]),
            ]
        )
        private let safePath: SafePath

        public init(workspace: URL) {
            self.safePath = SafePath(workspace: workspace)
        }

        public func run(arguments: [String: AnyCodable]) throws -> String {
            guard let raw = arguments["path"]?.value as? String else {
                throw ToolError.invalidArguments("缺少 path 参数")
            }
            let content = arguments["content"]?.value as? String ?? ""
            let target = try safePath.resolve(raw)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: target, atomically: true, encoding: .utf8)
            return "已写入 \(raw) (\(content.count) chars)"
        }
    }

    // MARK: - 记忆

    public struct SearchMemoryTool: Tool {
        public let name = "search_memory"
        public let spec = ToolSpec(
            name: "search_memory",
            description: "Search long-term memory for facts about the user.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["query": ["type": "string"]]),
                "required": AnyCodable(["query"]),
            ]
        )
        private let store: SQLiteStore
        private let persona: String
        private let topK: Int

        public init(store: SQLiteStore, persona: String, topK: Int = 5) {
            self.store = store
            self.persona = persona
            self.topK = topK
        }

        public func run(arguments: [String: AnyCodable]) throws -> String {
            let query = arguments["query"]?.value as? String ?? ""
            let items = try store.searchMemories(query: query, persona: persona, topK: topK)
            if items.isEmpty {
                return "没有找到相关记忆。"
            }
            return items.map { "- \($0.content)" }.joined(separator: "\n")
        }
    }

    public struct AddMemoryTool: Tool {
        public let name = "add_memory"
        public let spec = ToolSpec(
            name: "add_memory",
            description: "Save a fact to long-term memory.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["content": ["type": "string"]]),
                "required": AnyCodable(["content"]),
            ]
        )
        private let store: SQLiteStore
        private let persona: String

        public init(store: SQLiteStore, persona: String) {
            self.store = store
            self.persona = persona
        }

        public func run(arguments: [String: AnyCodable]) throws -> String {
            let content = arguments["content"]?.value as? String ?? ""
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "记忆内容为空。"
            }
            _ = try store.addMemory(persona: persona, content: content, kind: "long_term")
            return "已写入长期记忆。"
        }
    }

    // MARK: - 本地 Agent(macOS only)

    #if os(macOS)
    /// 调用本机安装的 Agent CLI(原版 run_local_agent)。
    /// agentCommands 为 agent 名 -> 可执行文件路径的映射(测试可注入 /bin/echo)。
    public struct RunLocalAgentTool: Tool {
        public let name = "run_local_agent"
        public let spec = ToolSpec(
            name: "run_local_agent",
            description: "Run a locally installed coding agent CLI (opencode, hermes, codex, claude, openclaw, astrbot) with a prompt.",
            parameters: [
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "agent": ["type": "string", "description": "opencode | hermes | codex | claude | openclaw | astrbot"],
                    "prompt": ["type": "string"],
                ]),
                "required": AnyCodable(["agent", "prompt"]),
            ]
        )
        private let agentCommands: [String: String]
        private let timeout: TimeInterval

        public init(
            agentCommands: [String: String] = [
                "opencode": "/usr/local/bin/opencode",
                "hermes": "/usr/local/bin/hermes",
                "codex": "/usr/local/bin/codex",
                "claude": "/usr/local/bin/claude",
                "openclaw": "/usr/local/bin/openclaw",
                "astrbot": "/usr/local/bin/astrbot",
            ],
            timeout: TimeInterval = 60
        ) {
            self.agentCommands = agentCommands
            self.timeout = timeout
        }

        public func run(arguments: [String: AnyCodable]) throws -> String {
            guard let agent = arguments["agent"]?.value as? String else {
                throw ToolError.invalidArguments("缺少 agent 参数")
            }
            let prompt = arguments["prompt"]?.value as? String ?? ""
            guard let executable = agentCommands[agent] else {
                return "未知 Agent: \(agent)"
            }
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                return "Agent \(agent) 未安装(找不到 \(executable))。"
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [prompt]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return "启动 Agent 失败: \(error.localizedDescription)"
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            _ = timeout
            let output = String(data: data, encoding: .utf8) ?? "(无输出)"
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(无输出)" : trimmed
        }
    }
    #endif
}
