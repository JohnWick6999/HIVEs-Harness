import Foundation

/// 工作区路径沙箱:阻止路径逃逸(对齐原版 `_safe_path`)。
public struct SafePath: Sendable {
    public let workspace: URL

    public init(workspace: URL) {
        self.workspace = workspace.standardizedFileURL
    }

    /// 将相对路径解析为工作区内的绝对 URL;任何逃逸尝试都抛 pathEscape。
    public func resolve(_ raw: String) throws -> URL {
        // 去除前导 / 和 \ ,强制相对化(对齐原版 lstrip)
        let cleaned = raw.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = workspace.appendingPathComponent(cleaned).standardizedFileURL
        let root = workspace.standardizedFileURL

        guard target == root || target.path.hasPrefix(root.path + "/") else {
            throw ToolError.pathEscape(raw)
        }
        return target
    }

    /// 解析任意路径:绝对路径原样使用(展开 ~),相对路径仍基于工作区。
    /// 是否允许越界由调用方的 `FileAccessPolicy` 决定。
    public func resolveAny(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return workspace.appendingPathComponent(expanded).standardizedFileURL
    }

    /// 路径是否位于工作区内(含工作区根目录)。
    public func isInsideWorkspace(_ url: URL) -> Bool {
        let root = workspace.standardizedFileURL
        let target = url.standardizedFileURL
        return target == root || target.path.hasPrefix(root.path + "/")
    }
}
