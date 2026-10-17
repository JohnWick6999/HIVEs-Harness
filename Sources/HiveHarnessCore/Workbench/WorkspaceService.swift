import Foundation

public struct WorkspaceEntry: Sendable, Equatable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, size: Int) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct ShellResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public enum WorkspaceError: Error, Sendable, Equatable {
    case invalidPath(String)
    case notFound(String)
    case isDirectory(String)
    case tooLarge(String)
    case unsupported
}

extension WorkspaceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "路径不在工作区: \(path)"
        case .notFound(let path): return "文件或目录不存在: \(path)"
        case .isDirectory(let path): return "这是目录,不是文件: \(path)"
        case .tooLarge(let path): return "文件过大,无法预览: \(path)"
        case .unsupported: return "当前平台不支持本机命令执行"
        }
    }
}

/// 工作台:工作区文件浏览、Git 变更、Shell。
public struct WorkspaceService: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: - 文件

    public func list(path: String = ".") throws -> [WorkspaceEntry] {
        let target = try resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.notFound(path)
        }
        guard isDirectory.boolValue else {
            throw WorkspaceError.isDirectory(path)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { $0.lastPathComponent != ".git" }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                let isDir = values.isDirectory ?? false
                return WorkspaceEntry(
                    path: relativePath(of: url),
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    size: isDir ? 0 : (values.fileSize ?? 0)
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    public func read(path: String, maxBytes: Int = 1_000_000) throws -> String {
        let target = try resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.notFound(path)
        }
        guard !isDirectory.boolValue else {
            throw WorkspaceError.isDirectory(path)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else {
            throw WorkspaceError.tooLarge(path)
        }
        let data = try Data(contentsOf: target)
        guard let text = String(data: data, encoding: .utf8) else {
            return "（二进制文件，\(data.count) 字节，无法以文本预览）"
        }
        return text
    }

    public func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        if target == rootPath { return "." }
        if target.hasPrefix(rootPath + "/") {
            return String(target.dropFirst(rootPath.count + 1))
        }
        return target
    }

    private func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: URL
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = root.appendingPathComponent(trimmed.isEmpty ? "." : trimmed)
        }
        let target = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootResolved = root.resolvingSymlinksInPath()
        guard target.path == rootResolved.path
                || target.path.hasPrefix(rootResolved.path + "/")
        else {
            throw WorkspaceError.invalidPath(path)
        }
        return target
    }

    // MARK: - Git

    public func gitStatus() -> String {
        #if os(macOS)
        return (try? run("/usr/bin/git", ["-C", root.path, "status", "--short"], timeout: 10).stdout) ?? ""
        #else
        return ""
        #endif
    }

    public func gitDiff() -> String {
        #if os(macOS)
        let stat = (try? run("/usr/bin/git", ["-C", root.path, "diff", "--stat"], timeout: 15).stdout) ?? ""
        let diff = (try? run("/usr/bin/git", ["-C", root.path, "diff"], timeout: 20).stdout) ?? ""
        return [stat, diff]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        #else
        return ""
        #endif
    }

    // MARK: - Shell

    public func runShell(_ command: String, timeout: TimeInterval = 60) throws -> ShellResult {
        #if os(macOS)
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorkspaceError.notFound("空命令")
        }
        return try run("/bin/zsh", ["-lc", trimmed], timeout: timeout)
        #else
        throw WorkspaceError.unsupported
        #endif
    }

    #if os(macOS)
    private func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiveharness-workbench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let outURL = base.appendingPathComponent("stdout")
        let errURL = base.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = outHandle
        process.standardError = errHandle

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        try process.run()
        let waitResult = semaphore.wait(timeout: .now() + timeout)

        var timedOut = false
        if waitResult == .timedOut {
            timedOut = true
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 2)
        }
        try? outHandle.close()
        try? errHandle.close()

        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        let code: Int32 = timedOut ? -1 : process.terminationStatus
        return ShellResult(
            exitCode: code,
            stdout: String(stdout.prefix(100_000)),
            stderr: String(stderr.prefix(100_000)),
            timedOut: timedOut
        )
    }
    #endif
}
