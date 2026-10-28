import AppKit
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
            return .unavailable("这台 Mac 不支持 Apple 智能。")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("系统设置中已关闭 Apple 智能。")
        case .unavailable(.modelNotReady):
            return .unavailable("设备端模型仍在下载中。")
        case .unavailable:
            return .unavailable("设备端模型当前不可用。")
        }
    }

    public func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        let candidates = categories.filter { !$0.isDoNotTrack && $0.key != CategoryDefinition.uncategorizedKey }
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

        let categoryList = candidates.map { "- \($0.key)：\($0.hint)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            你在为个人时间追踪器判断一个人此刻在 Mac 上做什么。
            只从下面的列表里选择一个分类 key：
            \(categoryList)

            按应用或网站本身的用途判断，不要被窗口标题里偶然出现的词带偏。
            只有当它是一个用途不明的网页浏览器标签页时才用 "browsing"，原生应用绝不要用。\
            遇到不认识的原生应用，从它的名称和 bundle identifier 推断用途。
            """)

        var prompt = context.domain == nil
            ? "原生应用：\(context.appName)（bundle identifier \(context.bundleID)）"
            : "\(context.appName) 中的网页标签页"
        if context.domain == nil, let category = Self.appStoreCategory(bundleID: context.bundleID) {
            prompt += "\nApp Store 分类：\(category)"
        }
        if let domain = context.domain { prompt += "\n网站：\(domain)" }
        if let title = context.title { prompt += "\n窗口标题：\(title.prefix(200))" }

        let response = try await session.respond(
            to: prompt, schema: schema, options: GenerationOptions(samplingMode: .greedy)
        )
        let key = try response.content.value(String.self, forProperty: "category")
        let confidence = try response.content.value(String.self, forProperty: "confidence")
        guard keys.contains(key) else { throw ClassificationError.unknownCategory(key) }
        return AIClassification(categoryKey: key, confidence: AIConfidence(rawValue: confidence) ?? .low)
    }

    public func describeActivity(_ facts: String, language: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            你在为一份个人工时记录写条目。给你一段电脑使用过程中的应用、网站和窗口标题，\
            用一句简体中文（不超过 40 个字）说明这个人做了什么。覆盖其中最要紧的两三件事，\
            点出标题里具体的项目、话题或页面，并说明是怎么做的（例如在终端里、在 GitHub 上）。\
            不要提时长、百分比，也不要提到你自己。要写得像母语者自然会说的一句话，例如：
            在终端里开发 weft 应用，在 GitHub 上查看 ActivityWatch 仓库，并调研了时间追踪工具的替代方案。
            """)
        return try await session.respond(to: facts).content
    }

    /// `public.app-category.developer-tools` → `developer tools`, from the app's Info.plist.
    static func appStoreCategory(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let type = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
              type.hasPrefix("public.app-category.") else { return nil }
        return type.dropFirst("public.app-category.".count).replacingOccurrences(of: "-", with: " ")
    }

    public func summarize(_ facts: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            你是一位有耐心的效率教练。根据某一天电脑使用的统计数据，用简体中文写一段简短回顾：\
            先用两三句话说说这一天过得怎么样，再给出一个具体、可执行的明天建议。\
            不要用标题，不要用列表。
            """)
        return try await session.respond(to: facts).content
    }
}

public enum ClassificationError: Error {
    case unknownCategory(String)
}
