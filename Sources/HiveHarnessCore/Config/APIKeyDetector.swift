import Foundation

/// 识别常见 API Key 形态,用于防止把 Key 误填到模型名/Base URL。
public enum APIKeyDetector {
    public static func looksLikeAPIKey(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 12, !text.contains(" ") else { return false }
        let lower = text.lowercased()
        if lower.hasPrefix("sk-") || lower.hasPrefix("sk_") { return true }
        if lower.hasPrefix("bearer ") { return true }
        if lower.hasPrefix("ghp_") || lower.hasPrefix("github_pat_") { return true }
        // 长随机串且包含常见 Key 前缀,避免把普通模型名误判。
        return text.count >= 40 && (lower.hasPrefix("sk") || lower.hasPrefix("key"))
    }

    /// 从模型字段中提取误填的 Key,并给出可用的模型名。
    public static func splitMisplacedKey(
        modelField: String,
        fallbackModel: String
    ) -> (model: String, key: String?) {
        guard looksLikeAPIKey(modelField) else {
            return (modelField, nil)
        }
        let fallback = fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = fallback.isEmpty || looksLikeAPIKey(fallback) ? "gpt-4o-mini" : fallback
        return (safe, modelField.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
