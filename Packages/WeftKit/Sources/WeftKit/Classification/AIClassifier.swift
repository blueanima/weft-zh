import Foundation
import FoundationModels

public enum AIConfidence: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}

public struct AIClassification: Sendable, Equatable {
    public var categoryKey: String
    public var confidence: AIConfidence

    public init(categoryKey: String, confidence: AIConfidence) {
        self.categoryKey = categoryKey
        self.confidence = confidence
    }
}

public enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Abstraction over the on-device model so tests can inject a fake.
public protocol AIClassifying: Sendable {
    func availability() -> AIAvailability
    func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification
    func summarize(_ facts: String) async throws -> String
    /// One sentence describing a stretch of activity, in `language`.
    func describeActivity(_ facts: String, language: String) async throws -> String
}

/// Classifies activity with Apple's on-device Foundation Models. The category list is
/// user-editable, so the output schema is built at runtime with `DynamicGenerationSchema`.
public struct FoundationModelsClassifier: AIClassifying {
    public init() {}

    public func availability() -> AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            // 未开放 Apple 智能的地区也会报这个值，所以别把话说成硬件不支持。
            return .unavailable("这台 Mac 或所在地区不提供 Apple 智能。")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("系统设置中已关闭 Apple 智能。")
        case .unavailable(.modelNotReady):
            return .unavailable("设备端模型仍在下载中。")
        case .unavailable:
            return .unavailable("设备端模型当前不可用。")
        }
    }

    public func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        let candidates = ModelPrompts.candidates(categories)
        let keys = candidates.map(\.key)

        let root = DynamicGenerationSchema(
            name: "活动分类",
            properties: [
                .init(
                    name: "category",
                    description: "最能描述该活动的分类 key。",
                    schema: DynamicGenerationSchema(name: "CategoryKey", anyOf: keys)
                ),
                .init(
                    name: "confidence",
                    description: "你的确定程度。如果这个应用或网站可能属于多个分类，用 low。",
                    schema: DynamicGenerationSchema(name: "Confidence", anyOf: AIConfidence.allCases.map(\.rawValue))
                ),
            ]
        )
        let schema = try GenerationSchema(root: root, dependencies: [])

        let session = LanguageModelSession(instructions: ModelPrompts.classifyInstructions(candidates))
        let prompt = ModelPrompts.classifyPrompt(context)

        let response = try await session.respond(
            to: prompt, schema: schema, options: GenerationOptions(samplingMode: .greedy)
        )
        let key = try response.content.value(String.self, forProperty: "category")
        let confidence = try response.content.value(String.self, forProperty: "confidence")
        guard keys.contains(key) else { throw ClassificationError.unknownCategory(key) }
        return AIClassification(categoryKey: key, confidence: AIConfidence(rawValue: confidence) ?? .low)
    }

    public func describeActivity(_ facts: String, language: String) async throws -> String {
        let session = LanguageModelSession(instructions: ModelPrompts.describeInstructions(language: language))
        return try await session.respond(to: facts).content
    }

    public func summarize(_ facts: String) async throws -> String {
        let session = LanguageModelSession(instructions: ModelPrompts.summarizeInstructions)
        return try await session.respond(to: facts).content
    }
}

public enum ClassificationError: Error {
    case unknownCategory(String)
}
