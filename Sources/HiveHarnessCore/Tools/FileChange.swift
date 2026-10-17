import Foundation

/// 一次文件写入的前后快照,用于聊天中的代码变更提示。
public struct FileChange: Sendable, Equatable {
    public var path: String
    public var oldText: String?
    public var newText: String
    public var language: String

    public init(path: String, oldText: String?, newText: String, language: String = "") {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.language = language
    }

    public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
    public var hasChanges: Bool { (oldText ?? "") != newText }
    public var diff: [DiffLine] { LineDiff.diff(old: oldText ?? "", new: newText) }
    public var addedLines: Int { diff.filter { $0.kind == .added }.count }
    public var removedLines: Int { diff.filter { $0.kind == .removed }.count }
}

public enum DiffLineKind: String, Sendable, Equatable {
    case context
    case added
    case removed
}

public struct DiffLine: Sendable, Equatable, Identifiable {
    public var kind: DiffLineKind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?

    public var id: String { "\(kind.rawValue)-\(oldLine ?? -1)-\(newLine ?? -1)-\(text.hashValue)" }

    public init(kind: DiffLineKind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
    }
}

/// 行级 LCS diff;超大文件退化为“旧全部删除 + 新全部新增”,避免 O(n²) 爆内存。
public enum LineDiff {
    public static func diff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if oldLines.isEmpty && newLines == [""] { return [] }

        if oldLines.count > 500 || newLines.count > 500 {
            return oldLines.enumerated().map {
                DiffLine(kind: .removed, text: $0.element, oldLine: $0.offset + 1)
            } + newLines.enumerated().map {
                DiffLine(kind: .added, text: $0.element, newLine: $0.offset + 1)
            }
        }

        let n = oldLines.count
        let m = newLines.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if oldLines[i] == newLines[j] {
                        lcs[i][j] = lcs[i + 1][j + 1] + 1
                    } else {
                        lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                    }
                }
            }
        }

        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if oldLines[i] == newLines[j] {
                result.append(DiffLine(kind: .context, text: oldLines[i], oldLine: i + 1, newLine: j + 1))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(DiffLine(kind: .removed, text: oldLines[i], oldLine: i + 1))
                i += 1
            } else {
                result.append(DiffLine(kind: .added, text: newLines[j], newLine: j + 1))
                j += 1
            }
        }
        while i < n {
            result.append(DiffLine(kind: .removed, text: oldLines[i], oldLine: i + 1))
            i += 1
        }
        while j < m {
            result.append(DiffLine(kind: .added, text: newLines[j], newLine: j + 1))
            j += 1
        }
        return result
    }
}
