import Foundation
import Testing
@testable import WeftKit

struct DeepSeekTests {
    @Test func reportsMissingKey() {
        #expect(DeepSeekClassifier(config: DeepSeekConfig()).availability() == .unavailable("还没有填写 DeepSeek API Key。"))
        #expect(DeepSeekClassifier(config: DeepSeekConfig(apiKey: "sk-test")).availability() == .available)
    }

    @Test func buildsEndpoint() {
        #expect(
            DeepSeekConfig(baseURL: "https://api.deepseek.com/").endpoint("chat/completions")?.absoluteString
                == "https://api.deepseek.com/chat/completions"
        )
        #expect(DeepSeekConfig(baseURL: " https://proxy.local/v1 ").endpoint("models")?.absoluteString
                == "https://proxy.local/v1/models")
        #expect(DeepSeekConfig(baseURL: "api.deepseek.com").endpoint("models") == nil)
    }

    @Test func parsesPlainJSON() throws {
        let result = try DeepSeekClassifier.parseClassification(
            #"{"category":"code","confidence":"high"}"#, keys: ["code", "writing"]
        )
        #expect(result == AIClassification(categoryKey: "code", confidence: .high))
    }

    @Test func parsesFencedJSON() throws {
        let reply = """
        ```json
        {"category": "design", "confidence": "medium"}
        ```
        """
        let result = try DeepSeekClassifier.parseClassification(reply, keys: ["design"])
        #expect(result == AIClassification(categoryKey: "design", confidence: .medium))
    }

    @Test func unknownConfidenceFallsBackToLow() throws {
        let result = try DeepSeekClassifier.parseClassification(
            #"{"category":"code"}"#, keys: ["code"]
        )
        #expect(result.confidence == .low)
    }

    @Test func rejectsUnknownCategory() throws {
        do {
            _ = try DeepSeekClassifier.parseClassification(#"{"category":"gaming"}"#, keys: ["code"])
            Issue.record("未知分类应当抛错")
        } catch let error as ClassificationError {
            guard case .unknownCategory(let key) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(key == "gaming")
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: DeepSeekError.self) {
            try DeepSeekClassifier.parseClassification("我猜是代码吧", keys: ["code"])
        }
    }

    @Test func coordinatorRespectsProvider() {
        let off = AICoordinator(settings: AISettings(provider: .off))
        if case .unavailable(let reason) = off.availability() {
            #expect(reason.contains("已关闭"))
        } else {
            Issue.record("关闭时应当不可用")
        }

        let deepSeek = AICoordinator(settings: AISettings(provider: .deepSeek, deepSeek: DeepSeekConfig(apiKey: "sk-test")))
        #expect(deepSeek.availability() == .available)
    }

    @Test func configUpdatesAtRuntime() {
        let coordinator = AICoordinator(settings: AISettings(provider: .deepSeek))
        #expect(coordinator.availability() != .available)
        coordinator.update(AISettings(provider: .deepSeek, deepSeek: DeepSeekConfig(apiKey: "sk-live")))
        #expect(coordinator.availability() == .available)
    }
}
