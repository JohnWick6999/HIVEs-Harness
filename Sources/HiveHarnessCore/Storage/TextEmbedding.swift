import Foundation

/// 本地哈希向量嵌入:零依赖、确定性、离线可用。
/// 对齐原版"hash embedding + 余弦相似度"的检索方案;
/// 后续可替换为 LLM embedding 或 NaturalLanguage 框架,接口不变。
public enum TextEmbedding {
    public static let dimensions = 64

    /// FNV-1a 哈希
    private static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// 基于字符二元组(bigram)的哈希向量:
    /// 中文检索效果优于单字袋(邻接字携带语义信息)。
    public static func hashVector(_ text: String) -> [Double] {
        let scalars = Array(text.unicodeScalars).map { UInt8(truncatingIfNeeded: $0.value) }
        var vector = [Double](repeating: 0, count: dimensions)

        func add(_ bytes: [UInt8], weight: Double) {
            let hash = fnv1a(bytes)
            let index = Int(hash % UInt64(dimensions))
            let sign: Double = (hash >> 32) & 1 == 1 ? 1 : -1
            vector[index] += sign * weight
        }

        // 单字符 + 相邻二元组
        for i in scalars.indices {
            add([scalars[i]], weight: 1)
            if i + 1 < scalars.count {
                add([scalars[i], scalars[i + 1]], weight: 1.5)
            }
        }
        return normalized(vector)
    }

    /// L2 归一化
    public static func normalized(_ vector: [Double]) -> [Double] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-12 else { return vector }
        return vector.map { $0 / norm }
    }

    /// 余弦相似度(入参应为归一化向量)
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        for i in a.indices {
            dot += a[i] * b[i]
        }
        return dot
    }

    /// 查询与记忆是否共享至少一个非空白字符。
    /// 哈希向量 64 维碰撞噪声大(实测无关文本余弦可达 0.3),
    /// 需先用共享字符过滤,再做余弦排序。
    public static func hasSharedCharacters(_ query: String, _ content: String) -> Bool {
        let querySet = Set(query.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        let contentSet = Set(content.unicodeScalars)
        return !querySet.isDisjoint(with: contentSet)
    }
}
