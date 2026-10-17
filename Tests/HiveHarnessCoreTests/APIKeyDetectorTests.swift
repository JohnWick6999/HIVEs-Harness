import Foundation
@testable import HiveHarnessCore
import Testing

@Suite("API Key 防误填")
struct APIKeyDetectorTests {
    @Test("识别常见 Key 形态")
    func detection() {
        #expect(APIKeyDetector.looksLikeAPIKey("sk-test-not-a-real-key"))
        #expect(APIKeyDetector.looksLikeAPIKey("sk-proj-abcdefghijklmnop"))
        #expect(!APIKeyDetector.looksLikeAPIKey("deepseek-chat"))
        #expect(!APIKeyDetector.looksLikeAPIKey("gpt-4o-mini"))
        #expect(!APIKeyDetector.looksLikeAPIKey(""))
    }

    @Test("模型字段中误填 Key 时恢复模型名")
    func split() {
        let result = APIKeyDetector.splitMisplacedKey(
            modelField: "sk-test-not-a-real-key",
            fallbackModel: "deepseek-chat"
        )
        #expect(result.model == "deepseek-chat")
        #expect(result.key == "sk-test-not-a-real-key")

        let normal = APIKeyDetector.splitMisplacedKey(
            modelField: "deepseek-chat",
            fallbackModel: "deepseek-chat"
        )
        #expect(normal.key == nil)
        #expect(normal.model == "deepseek-chat")
    }
}
