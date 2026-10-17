import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Glob

public struct GlobTool: Tool {
    public let name = "glob"
    public let spec = ToolSpec(
        name: "glob",
        description: "Find files by glob pattern, e.g. **/*.swift or Sources/**/*.md. Skips .git, node_modules and build directories.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "pattern": ["type": "string", "description": "Glob 模式"],
                "path": ["type": "string", "description": "搜索根目录,默认工作区"],
                "limit": ["type": "integer", "description": "最多返回数量,默认 200"],
            ]),
            "required": AnyCodable(["pattern"]),
        ]
    )
    private let safePath: SafePath
    private let policy: FileAccessPolicy

    public init(workspace: URL, policy: FileAccessPolicy = FileAccessPolicy(mode: .sandbox)) {
        self.safePath = SafePath(workspace: workspace)
        self.policy = policy
    }

    public func run(arguments: [String: AnyCodable]) throws -> ToolResult {
        let pattern = (arguments["pattern"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { throw ToolError.invalidArguments("glob 需要 pattern") }
        let rawPath = arguments["path"]?.value as? String ?? "."
        let root = try policy.resolveRead(rawPath, safePath: safePath)
        let limit = min(1_000, max(1, arguments["limit"]?.value as? Int ?? 200))
        let regex = try NSRegularExpression(pattern: CodePath.globRegex(pattern))
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ToolResult(text: "目录不可读: \(root.path)") }

        var matches: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if CodePath.skipDirectory(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            let relative = CodePath.relative(url, root: root)
            let range = NSRange(relative.startIndex..<relative.endIndex, in: relative)
            if regex.firstMatch(in: relative, range: range) != nil {
                matches.append(relative)
                if matches.count >= limit { break }
            }
        }
        return ToolResult(
            text: matches.isEmpty ? "未找到匹配: \(pattern)" : matches.joined(separator: "\n")
        )
    }
}

// MARK: - Grep

public struct GrepTool: Tool {
    public let name = "grep"
    public let spec = ToolSpec(
        name: "grep",
        description: "Search file contents with a regular expression. Returns path:line:text. Skips binary and build directories.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "pattern": ["type": "string"],
                "path": ["type": "string", "description": "搜索根目录,默认工作区"],
                "glob": ["type": "string", "description": "可选文件过滤,如 **/*.swift"],
                "case_sensitive": ["type": "boolean"],
                "limit": ["type": "integer"],
            ]),
            "required": AnyCodable(["pattern"]),
        ]
    )
    private let safePath: SafePath
    private let policy: FileAccessPolicy

    public init(workspace: URL, policy: FileAccessPolicy = FileAccessPolicy(mode: .sandbox)) {
        self.safePath = SafePath(workspace: workspace)
        self.policy = policy
    }

    public func run(arguments: [String: AnyCodable]) throws -> ToolResult {
        let pattern = arguments["pattern"]?.value as? String ?? ""
        guard !pattern.isEmpty else { throw ToolError.invalidArguments("grep 需要 pattern") }
        let rawPath = arguments["path"]?.value as? String ?? "."
        let root = try policy.resolveRead(rawPath, safePath: safePath)
        let limit = min(500, max(1, arguments["limit"]?.value as? Int ?? 100))
        let caseSensitive = arguments["case_sensitive"]?.value as? Bool ?? false
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let glob = arguments["glob"]?.value as? String
        let fileRegex = glob.map { try? NSRegularExpression(pattern: CodePath.globRegex($0)) } ?? nil
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return ToolResult(text: "目录不可读: \(root.path)") }

        var lines: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if CodePath.skipDirectory(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 2_000_000 else { continue }
            let relative = CodePath.relative(url, root: root)
            if let fileRegex {
                let range = NSRange(relative.startIndex..<relative.endIndex, in: relative)
                if fileRegex.firstMatch(in: relative, range: range) == nil { continue }
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  !content.contains("\0") else { continue }
            for (index, line) in content.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    lines.append("\(relative):\(index + 1):\(line)")
                    if lines.count >= limit { break }
                }
            }
            if lines.count >= limit { break }
        }
        return ToolResult(text: lines.isEmpty ? "未找到匹配: \(pattern)" : lines.joined(separator: "\n"))
    }
}

// MARK: - Edit

public struct EditFileTool: Tool {
    public let name = "edit_file"
    public let spec = ToolSpec(
        name: "edit_file",
        description: "Replace an exact string in a text file. Prefer this over rewriting the whole file. Fails if old_string is missing or ambiguous unless replace_all is true.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string"],
                "old_string": ["type": "string"],
                "new_string": ["type": "string"],
                "replace_all": ["type": "boolean"],
            ]),
            "required": AnyCodable(["path", "old_string", "new_string"]),
        ]
    )
    private let safePath: SafePath
    private let policy: FileAccessPolicy

    public init(workspace: URL, policy: FileAccessPolicy = FileAccessPolicy(mode: .sandbox)) {
        self.safePath = SafePath(workspace: workspace)
        self.policy = policy
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let raw = arguments["path"]?.value as? String,
              let oldString = arguments["old_string"]?.value as? String,
              let newString = arguments["new_string"]?.value as? String
        else { throw ToolError.invalidArguments("edit_file 需要 path/old_string/new_string") }
        guard !oldString.isEmpty else { throw ToolError.invalidArguments("old_string 不能为空") }
        let target = try await policy.resolveWrite(raw, safePath: safePath)
        let oldText = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let count = oldText.components(separatedBy: oldString).count - 1
        guard count > 0 else { throw ToolError.execution("未找到 old_string") }
        let replaceAll = arguments["replace_all"]?.value as? Bool ?? false
        guard replaceAll || count == 1 else {
            throw ToolError.execution("old_string 出现 \(count) 次;请提供更多上下文或使用 replace_all")
        }
        let updated = oldText.replacingOccurrences(
            of: oldString,
            with: newString,
            options: replaceAll ? [] : [.literal],
            range: oldText.startIndex..<oldText.endIndex
        )
        try updated.write(to: target, atomically: true, encoding: .utf8)
        let change = FileChange(
            path: target.path,
            oldText: oldText,
            newText: updated,
            language: target.pathExtension
        )
        return ToolResult(
            text: "已编辑 \(target.path) (\(count) 处)",
            files: [target],
            changes: [change]
        )
    }
}

// MARK: - Shell

public struct ShellTool: Tool {
    public let name = "shell"
    public let spec = ToolSpec(
        name: "shell",
        description: "Run a shell command in the workspace. Full-control mode only; requires approval. Use for tests, builds, git, and package managers.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "command": ["type": "string"],
                "timeout_seconds": ["type": "integer", "description": "默认 60,最大 300"],
            ]),
            "required": AnyCodable(["command"]),
        ]
    )
    private let workspace: URL

    public init(workspace: URL) {
        self.workspace = workspace
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let command = (arguments["command"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw ToolError.invalidArguments("shell 需要 command") }
        let timeout = min(300, max(1, arguments["timeout_seconds"]?.value as? Int ?? 60))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workspace
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let box = ShellProcessBox(process)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .seconds(timeout))
        timer.setEventHandler {
            box.terminate()
        }
        timer.resume()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()

        let output = String(data: data.prefix(32_000), encoding: .utf8) ?? ""
        let status = process.terminationStatus
        let head = "exit \(status)" + (box.timedOut ? " (timeout)" : "")
        return ToolResult(text: "\(head)\n\n\(output.isEmpty ? "(无输出)" : output)")
    }
}

private final class ShellProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var _timedOut = false

    init(_ process: Process) { self.process = process }

    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return _timedOut
    }

    func terminate() {
        lock.lock(); _timedOut = true; lock.unlock()
        if process.isRunning { process.terminate() }
        let pid = process.processIdentifier
        if pid > 0 { kill(pid, SIGKILL) }
    }
}

// MARK: - Web Search

public struct WebSearchTool: Tool {
    public let name = "web_search"
    public let spec = ToolSpec(
        name: "web_search",
        description: "Search the public web and return result titles, URLs and snippets. Use for current facts; follow with http_get for full pages.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "query": ["type": "string"],
                "limit": ["type": "integer", "description": "1-10,默认 5"],
            ]),
            "required": AnyCodable(["query"]),
        ]
    )
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let query = (arguments["query"]?.value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError.invalidArguments("web_search 需要 query") }
        let limit = min(10, max(1, arguments["limit"]?.value as? Int ?? 5))
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("HiveHarness/0.1 (macOS Agent)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ToolError.execution("搜索服务不可用")
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        let results = Self.parse(html: html, limit: limit)
        guard !results.isEmpty else {
            return ToolResult(text: "未解析到搜索结果。可改用 http_get 直接访问搜索页。")
        }
        return ToolResult(text: results.joined(separator: "\n\n"))
    }

    private static func parse(html: String, limit: Int) -> [String] {
        let pattern = #"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var results: [String] = []
        for match in matches.prefix(limit) {
            guard match.numberOfRanges >= 3 else { continue }
            let rawURL = ns.substring(with: match.range(at: 1))
            let rawTitle = ns.substring(with: match.range(at: 2))
            let title = stripHTML(rawTitle)
            let url = cleanURL(rawURL)
            if !title.isEmpty, !url.isEmpty {
                results.append("• \(title)\n  \(url)")
            }
        }
        return results
    }

    private static func cleanURL(_ raw: String) -> String {
        var value = raw
        if let range = value.range(of: "uddg=") {
            value = String(value[range.upperBound...])
            if let amp = value.firstIndex(of: "&") { value = String(value[..<amp]) }
            value = value.removingPercentEncoding ?? value
        }
        if value.hasPrefix("//") { value = "https:" + value }
        return value
    }

    private static func stripHTML(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - PDF

#if canImport(PDFKit)
public struct ReadPDFTool: Tool {
    public let name = "read_pdf"
    public let spec = ToolSpec(
        name: "read_pdf",
        description: "Extract text from a local PDF, page by page. Use for papers, specs and manuals.",
        parameters: [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "path": ["type": "string"],
                "max_pages": ["type": "integer", "description": "默认 30,最大 100"],
            ]),
            "required": AnyCodable(["path"]),
        ]
    )
    private let safePath: SafePath
    private let policy: FileAccessPolicy

    public init(workspace: URL, policy: FileAccessPolicy = FileAccessPolicy(mode: .sandbox)) {
        self.safePath = SafePath(workspace: workspace)
        self.policy = policy
    }

    public func run(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let raw = arguments["path"]?.value as? String else {
            throw ToolError.invalidArguments("read_pdf 需要 path")
        }
        let url = try policy.resolveRead(raw, safePath: safePath)
        guard let document = PDFDocument(url: url) else {
            throw ToolError.execution("无法打开 PDF: \(url.path)")
        }
        let limit = min(100, max(1, arguments["max_pages"]?.value as? Int ?? 30))
        var pages: [String] = []
        for index in 0..<min(document.pageCount, limit) {
            let text = document.page(at: index)?.string ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append("[第 \(index + 1) 页]\n\(text)")
            }
        }
        return ToolResult(text: pages.isEmpty ? "(PDF 无可提取文本)" : pages.joined(separator: "\n\n"))
    }
}
#endif

// MARK: - Helpers

enum CodePath {
    static func skipDirectory(_ name: String) -> Bool {
        [".git", "node_modules", ".build", "DerivedData", ".next", "dist", "build", ".idea"].contains(name)
    }

    static func relative(_ url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.path
    }

    static func globRegex(_ pattern: String) -> String {
        let source = pattern.contains("/") ? pattern : "**/\(pattern)"
        var regex = "^"
        var index = source.startIndex
        while index < source.endIndex {
            let char = source[index]
            if char == "*" {
                let next = source.index(after: index)
                if next < source.endIndex, source[next] == "*" {
                    index = next
                    let after = source.index(after: index)
                    if after < source.endIndex, source[after] == "/" {
                        regex += "(?:.*/)?"
                        index = after
                    } else {
                        regex += ".*"
                    }
                } else {
                    regex += "[^/]*"
                }
            } else if char == "?" {
                regex += "[^/]"
            } else if ".+()^$|{}[]\\".contains(char) {
                regex += "\\\(char)"
            } else {
                regex += String(char)
            }
            index = source.index(after: index)
        }
        regex += "$"
        return regex
    }
}
