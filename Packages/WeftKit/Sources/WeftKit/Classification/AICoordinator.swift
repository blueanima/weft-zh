import Foundation

/// Which engine turns activity into categories and sentences.
public enum AIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case deepSeek
    case apple
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .apple: "Apple 智能"
        case .off: "关闭"
        }
    }

    public var detail: String {
        switch self {
        case .deepSeek: "云端调用 DeepSeek，按 token 计费。"
        case .apple: "设备端模型，不联网。"
        case .off: "只用内置规则和缓存分类。"
        }
    }
}

public struct AISettings: Sendable, Equatable {
    public var provider: AIProvider
    public var deepSeek: DeepSeekConfig

    public init(provider: AIProvider = .deepSeek, deepSeek: DeepSeekConfig = .init()) {
        self.provider = provider
        self.deepSeek = deepSeek
    }
}

/// Routes the three AI entry points to whichever engine the user picked. Configuration can be
/// updated at runtime, so switching engine in Settings takes effect on the next call.
public final class AICoordinator: AIClassifying, @unchecked Sendable {
    public let deepSeek: DeepSeekClassifier
    private let apple = FoundationModelsClassifier()
    private let lock = NSLock()
    private var settings: AISettings

    public init(settings: AISettings = .init()) {
        self.settings = settings
        deepSeek = DeepSeekClassifier(config: settings.deepSeek)
    }

    public var currentSettings: AISettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    public func update(_ settings: AISettings) {
        lock.lock()
        self.settings = settings
        lock.unlock()
        deepSeek.update(config: settings.deepSeek)
    }

    public func availability() -> AIAvailability {
        switch currentSettings.provider {
        case .off: .unavailable("AI 引擎已关闭，只用内置规则分类。")
        case .apple: apple.availability()
        case .deepSeek: deepSeek.availability()
        }
    }

    public func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        switch currentSettings.provider {
        case .off: throw DeepSeekError.missingKey
        case .apple: return try await apple.classify(context, categories: categories)
        case .deepSeek: return try await deepSeek.classify(context, categories: categories)
        }
    }

    public func summarize(_ facts: String) async throws -> String {
        switch currentSettings.provider {
        case .off: throw DeepSeekError.missingKey
        case .apple: return try await apple.summarize(facts)
        case .deepSeek: return try await deepSeek.summarize(facts)
        }
    }

    public func describeActivity(_ facts: String, language: String) async throws -> String {
        switch currentSettings.provider {
        case .off: throw DeepSeekError.missingKey
        case .apple: return try await apple.describeActivity(facts, language: language)
        case .deepSeek: return try await deepSeek.describeActivity(facts, language: language)
        }
    }
}
