import Foundation
import Synchronization

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
        case .off: "只用内置规则和缓存分类，认不出的先按 App Store 分类和域名推测。"
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

public enum AIError: LocalizedError, Equatable {
    case disabled

    public var errorDescription: String? {
        switch self {
        case .disabled: "AI 引擎已关闭。"
        }
    }
}

/// 关掉 AI 时的占位引擎。它不给可用性，调用一律报「已关闭」，这样上层能区分
/// 「用户主动关了」和「Key 没填对」，也免得 `.off` 那条分支到处抛缺 Key 的错。
private struct DisabledModel: AIClassifying {
    func availability() -> AIAvailability { .unavailable("AI 引擎已关闭，只用内置规则分类。") }

    func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        throw AIError.disabled
    }

    func summarize(_ facts: String) async throws -> String { throw AIError.disabled }

    func describeActivity(_ facts: String, language: String) async throws -> String { throw AIError.disabled }
}

/// 把分类、摘要、条目三处调用转发给设置里选中的引擎。换引擎立刻生效，
/// 所以调用方可以一直持有同一个引用。
public final class AICoordinator: AIClassifying {
    public let deepSeek: DeepSeekClassifier
    private let apple: FoundationModelsClassifier
    private let state: Mutex<State>

    private struct State: Sendable {
        var settings: AISettings
        var engine: any AIClassifying
    }

    public init(settings: AISettings = .init()) {
        let deepSeek = DeepSeekClassifier(config: settings.deepSeek)
        let apple = FoundationModelsClassifier()
        self.deepSeek = deepSeek
        self.apple = apple
        state = Mutex(State(settings: settings, engine: Self.makeEngine(settings, deepSeek: deepSeek, apple: apple)))
    }

    public var currentSettings: AISettings {
        state.withLock { $0.settings }
    }

    /// 直接塞一个引擎进来，测试里用来模拟「模型上线了」。
    public init(model: any AIClassifying) {
        let deepSeek = DeepSeekClassifier(config: .init())
        let apple = FoundationModelsClassifier()
        self.deepSeek = deepSeek
        self.apple = apple
        state = Mutex(State(settings: .init(), engine: model))
    }

    /// 换配置。DeepSeek 的 Key、模型、地址在这里同步给具体实例，设置页的测试连接才用得上。
    public func update(_ settings: AISettings) {
        deepSeek.update(config: settings.deepSeek)
        let engine = Self.makeEngine(settings, deepSeek: deepSeek, apple: apple)
        state.withLock { $0 = State(settings: settings, engine: engine) }
    }

    /// 直接换掉当前引擎，用于测试里模拟模型上线。
    public func use(_ model: any AIClassifying) {
        state.withLock { $0.engine = model }
    }

    private var engine: any AIClassifying {
        state.withLock { $0.engine }
    }

    public func availability() -> AIAvailability { engine.availability() }

    public func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        try await engine.classify(context, categories: categories)
    }

    public func summarize(_ facts: String) async throws -> String {
        try await engine.summarize(facts)
    }

    public func describeActivity(_ facts: String, language: String) async throws -> String {
        try await engine.describeActivity(facts, language: language)
    }

    private static func makeEngine(
        _ settings: AISettings, deepSeek: DeepSeekClassifier, apple: FoundationModelsClassifier
    ) -> any AIClassifying {
        switch settings.provider {
        case .deepSeek: deepSeek
        case .apple: apple
        case .off: DisabledModel()
        }
    }
}
