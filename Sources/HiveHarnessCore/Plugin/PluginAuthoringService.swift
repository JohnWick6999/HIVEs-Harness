import Foundation

public enum PluginAuthoringError: Error, Sendable, Equatable {
    case invalidManifest(String)
    case pathEscape(String)
    case noInstallableContent
    case io(String)
}

extension PluginAuthoringError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let message): return "插件清单无效: \(message)"
        case .pathEscape(let path): return "插件文件路径越界: \(path)"
        case .noInstallableContent: return "插件至少需要一个 SKILL.md 或 MCP 服务器"
        case .io(let message): return "插件文件操作失败: \(message)"
        }
    }
}

/// 插件工坊:在本地创建、编辑、校验、安装、导出声明式插件。
/// 只处理 SKILL.md 与 MCP 配置,不执行插件代码。
public struct PluginAuthoringService: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - 项目

    public func listProjects() -> [PluginProject] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { loadProject(root: $0) }
            .sorted { $0.manifest.name.localizedCompare($1.manifest.name) == .orderedAscending }
    }

    public func loadProject(id: String) -> PluginProject? {
        loadProject(root: root.appendingPathComponent(id, isDirectory: true))
    }

    public func create(name: String, template: PluginTemplate) throws -> PluginProject {
        let base = Self.slug(name.isEmpty ? template.title : name)
        var id = base
        var counter = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path) {
            id = "\(base)-\(counter)"
            counter += 1
        }
        let projectRoot = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { _ = try? loadProject(root: projectRoot) }

        let skillPath = "skills/\(id)/SKILL.md"
        var manifest = PluginManifest(
            id: id,
            name: name.isEmpty ? template.title : name,
            version: "0.1.0",
            description: template.detail,
            author: "You",
            tags: [template.rawValue],
            skills: []
        )
        switch template {
        case .skillPack:
            manifest.skills = [skillPath]
        case .mcpBridge:
            manifest.mcpServers = [Self.templateMCP(id: id)]
        case .hybrid:
            manifest.skills = [skillPath]
            manifest.mcpServers = [Self.templateMCP(id: id)]
        }

        try writeManifest(manifest, to: projectRoot)
        try writeREADME(manifest, to: projectRoot)
        if !manifest.skills.isEmpty {
            try writeSkillTemplate(manifest, relativePath: skillPath, to: projectRoot)
        }
        guard let project = loadProject(root: projectRoot) else {
            throw PluginAuthoringError.io("创建后无法读取项目")
        }
        return project
    }

    public func deleteProject(id: String) throws {
        let target = root.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw PluginAuthoringError.invalidManifest("项目不存在: \(id)")
        }
        try FileManager.default.removeItem(at: target)
    }

    // MARK: - 文件

    public func readFile(project: PluginProject, path: String) throws -> String {
        let url = try safeURL(project.root, path: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw PluginAuthoringError.io("无法读取 \(path)")
        }
        return text
    }

    public func writeFile(project: PluginProject, path: String, content: String) throws {
        let url = try safeURL(project.root, path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 重新读取 manifest(编辑 plugin.json 后调用)。
    public func refresh(project: PluginProject) -> PluginProject? {
        loadProject(root: project.root)
    }

    // MARK: - 校验

    public func validate(project: PluginProject) -> PluginValidationReport {
        var issues: [PluginValidationIssue] = []
        let manifest = project.manifest

        if manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .error, message: "id 不能为空"))
        }
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .error, message: "name 不能为空"))
        }
        if manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(severity: .warning, message: "version 为空,将使用 0.1.0"))
        }

        let skillPaths = resolvedSkillPaths(project)
        if skillPaths.count > 12 {
            issues.append(.init(severity: .error, message: "一个插件最多 12 个技能"))
        }
        for path in skillPaths {
            let normalized = Self.normalizedPath(path)
            guard let url = try? safeURL(project.root, path: normalized),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else {
                issues.append(.init(severity: .error, path: path, message: "SKILL.md 不存在或不可读"))
                continue
            }
            if text.utf8.count > 512_000 {
                issues.append(.init(severity: .error, path: path, message: "SKILL.md 超过 512KB"))
            }
            let parsed = SkillStore.parseFrontmatter(text)
            let name = (parsed.meta["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let description = (parsed.meta["description"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                issues.append(.init(severity: .error, path: path, message: "SKILL.md 缺少 name"))
            }
            if description.isEmpty {
                issues.append(.init(severity: .warning, path: path, message: "SKILL.md 缺少 description"))
            }
            if parsed.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(severity: .error, path: path, message: "SKILL.md 正文为空"))
            }
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            let siblingScripts = project.files.filter {
                $0.hasPrefix(parent + "/")
                    && ($0.hasSuffix(".sh") || $0.hasSuffix(".py"))
            }
            if !siblingScripts.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    path: path,
                    message: "同目录包含脚本;首版只安装 SKILL.md,不会执行脚本"
                ))
            }
        }

        for config in manifest.mcpServers {
            if config.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(severity: .error, message: "MCP 服务器 id 不能为空"))
            }
            if config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               config.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(
                    severity: .error,
                    path: config.id,
                    message: "MCP 服务器需要 command 或 url"
                ))
            }
            if config.enabled {
                issues.append(.init(
                    severity: .warning,
                    path: config.id,
                    message: "MCP 默认停用;安装后请在设置中审查再启用"
                ))
            }
        }

        if skillPaths.isEmpty && manifest.mcpServers.isEmpty {
            issues.append(.init(severity: .error, message: "至少需要一个 SKILL.md 或 MCP 服务器"))
        }
        if !manifest.commands.isEmpty {
            issues.append(.init(
                severity: .warning,
                message: "commands 目前仅兼容展示,不会执行"
            ))
        }
        if !manifest.hooks.isEmpty {
            issues.append(.init(
                severity: .warning,
                message: "hooks 目前仅兼容展示,不会执行"
            ))
        }
        return PluginValidationReport(issues: issues)
    }

    // MARK: - 安装

    /// 安装技能文件与 MCP 配置;MCP 一律以停用状态写入,等待用户审查。
    public func install(
        project: PluginProject,
        skillStore: SkillStore,
        mcpDirectory: URL
    ) throws -> [Skill] {
        let report = validate(project: project)
        guard report.canInstall else {
            throw PluginAuthoringError.invalidManifest(
                report.errors.first?.message ?? "插件校验失败"
            )
        }

        var installed: [Skill] = []
        let skillPaths = resolvedSkillPaths(project)

        for path in skillPaths {
            let source = try safeURL(project.root, path: path)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("hive-plugin-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let destination = temp.appendingPathComponent("SKILL.md")
            try FileManager.default.copyItem(at: source, to: destination)
            installed.append(try skillStore.install(from: temp))
        }

        if !project.manifest.mcpServers.isEmpty {
            var existing = MCPConfigLoader.load(directory: mcpDirectory)
            let existingIDs = Set(existing.map(\.id))
            for var config in project.manifest.mcpServers where !existingIDs.contains(config.id) {
                config.enabled = false
                existing.append(config)
            }
            try MCPConfigLoader.save(existing, directory: mcpDirectory)
        }
        return installed
    }

    // MARK: - 导出 / 导入

    public func exportBundle(project: PluginProject) throws -> Data {
        var files: [String: String] = [:]
        for path in project.files {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            guard ["md", "json", "txt", "yaml", "yml"].contains(ext) else { continue }
            if let text = try? readFile(project: project, path: path), text.utf8.count <= 512_000 {
                files[path] = text
            }
        }
        let bundle = PluginBundle(manifest: project.manifest, files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    public func importBundle(data: Data, name: String? = nil) throws -> PluginProject {
        let bundle = try JSONDecoder().decode(PluginBundle.self, from: data)
        var manifest = bundle.manifest
        if manifest.id.isEmpty {
            manifest.id = Self.slug(name ?? manifest.name)
        }
        var id = Self.slug(manifest.id)
        var counter = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path) {
            id = "\(Self.slug(manifest.id))-\(counter)"
            counter += 1
        }
        manifest.id = id
        let projectRoot = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        try writeManifest(manifest, to: projectRoot)
        for (path, content) in bundle.files {
            let normalized = Self.normalizedPath(path)
            guard !normalized.isEmpty, !normalized.hasPrefix("..") else { continue }
            // manifest 以导入后的 id 为准,不覆盖
            if normalized == "plugin.json" || normalized.hasSuffix("/plugin.json") {
                continue
            }
            let url = try safeURL(projectRoot, path: normalized)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        guard let project = loadProject(root: projectRoot) else {
            throw PluginAuthoringError.io("导入后无法读取项目")
        }
        return project
    }

    // MARK: - 内部

    private func loadProject(root projectRoot: URL) -> PluginProject? {
        let manifestURL = projectRoot.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = PluginManifestParser.parse(data)
        else { return nil }
        return PluginProject(
            manifest: manifest,
            root: projectRoot,
            files: Self.allFiles(in: projectRoot)
        )
    }

    private func writeManifest(_ manifest: PluginManifest, to projectRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: projectRoot.appendingPathComponent("plugin.json"),
            options: .atomic
        )
    }

    private func writeREADME(_ manifest: PluginManifest, to projectRoot: URL) throws {
        let text = """
        # \(manifest.name)

        \(manifest.description)

        - id: `\(manifest.id)`
        - version: `\(manifest.version)`

        ## 组成

        - Skills: \(manifest.skills.count)
        - MCP: \(manifest.mcpServers.count)

        > HIVE 插件只安装 SKILL.md 与 MCP 配置,不执行插件代码。
        """
        try text.write(
            to: projectRoot.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeSkillTemplate(
        _ manifest: PluginManifest,
        relativePath: String,
        to projectRoot: URL
    ) throws {
        let text = """
        ---
        id: \(manifest.id)-skill
        name: \(manifest.name)
        description: \(manifest.name) 的工作流程
        version: \(manifest.version)
        author: \(manifest.author.isEmpty ? "You" : manifest.author)
        ---

        # \(manifest.name)

        1. 先确认输入与目标。
        2. 按步骤执行,并在每一步验证结果。
        3. 输出结论、风险与下一步。
        """
        let url = try safeURL(projectRoot, path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func templateMCP(id: String) -> MCPServerConfig {
        MCPServerConfig(
            id: "\(id)-server",
            name: "\(id) MCP",
            description: "替换 command/args 或 url 后启用",
            type: "stdio",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            enabled: false
        )
    }

    /// 兼容 Claude 的 `"skills": "./skills"` 目录声明。
    private func resolvedSkillPaths(_ project: PluginProject) -> [String] {
        let declared = project.manifest.skills.isEmpty
            ? project.files.filter { $0.hasSuffix("SKILL.md") }
            : project.manifest.skills
        var result: [String] = []
        for path in declared {
            let normalized = Self.normalizedPath(path)
            if normalized.hasSuffix("SKILL.md") {
                if !result.contains(normalized) { result.append(normalized) }
                continue
            }
            let prefix = normalized + "/"
            let nested = project.files.filter {
                $0.hasPrefix(prefix) && $0.hasSuffix("SKILL.md")
            }
            if nested.isEmpty {
                if !result.contains(normalized) { result.append(normalized) }
            } else {
                for item in nested where !result.contains(item) {
                    result.append(item)
                }
            }
        }
        return result
    }

    private func safeURL(_ root: URL, path: String) throws -> URL {
        let normalized = Self.normalizedPath(path)
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let target = base.appendingPathComponent(normalized).standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            throw PluginAuthoringError.pathEscape(path)
        }
        return target
    }

    private static func normalizedPath(_ path: String) -> String {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("./") { text.removeFirst(2) }
        while text.hasPrefix("/") { text.removeFirst() }
        return text
    }

    private static func allFiles(in root: URL) -> [String] {
        let fm = FileManager.default
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [String] = []
        for case let url as URL in enumerator {
            let resolved = url.resolvingSymlinksInPath()
            let prefix = base.path + "/"
            let relative = resolved.path.hasPrefix(prefix)
                ? String(resolved.path.dropFirst(prefix.count))
                : url.lastPathComponent
            if relative.hasPrefix(".git/") || relative.hasPrefix("node_modules/") {
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(relative)
            }
            if files.count > 200 { break }
        }
        return files.sorted()
    }

    private static func slug(_ raw: String) -> String {
        var result = ""
        for character in raw.lowercased() {
            if (character.isASCII && character.isLetter)
                || (character.isASCII && character.isNumber)
                || character == "-" || character == "_" || character == "." {
                result.append(character)
            } else {
                result.append("-")
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return result.isEmpty ? "plugin" : String(result.prefix(60))
    }
}
