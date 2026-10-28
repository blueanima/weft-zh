import Foundation
import SwiftData
import Testing
@testable import WeftKit

private final class FakeAI: AIClassifying, @unchecked Sendable {
    let answer: AIClassification
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(answer: AIClassification) { self.answer = answer }

    func availability() -> AIAvailability { .available }

    func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        lock.withLock { _calls += 1 }
        return answer
    }

    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

/// 一个模型都没有，比如 Apple 智能没开、DeepSeek 没填 Key。
private struct NoModel: AIClassifying {
    func availability() -> AIAvailability { .unavailable("test") }
    func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        throw ClassificationError.unknownCategory("")
    }
    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

/// 接口说可用，但每次调用都失败，像服务端连不上。
private struct FailingModel: AIClassifying {
    func availability() -> AIAvailability { .available }
    func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        throw URLError(.notConnectedToInternet)
    }
    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

@MainActor
struct ClassificationServiceTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try WeftSchema.makeContainer(inMemory: true)
        context = container.mainContext
    }

    func waitForQueue(_ service: ClassificationService) async {
        for _ in 0..<100 where service.queuedCount > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func seedsDefaultCategories() {
        let service = ClassificationService(modelContext: context, ai: FakeAI(answer: .init(categoryKey: "code", confidence: .high)))
        #expect(service.categories.count == CategoryDefinition.defaults.count)
        #expect(service.category("social_media").blockInFocus)
    }

    /// 从英文版升级上来时，还挂着英文默认名的分类要变成中文，用户改过名的保持不变。
    @Test func migratesLegacyEnglishCategoryNames() throws {
        let code = CategoryDefinition(key: "code", name: "Code", colorHex: "#4F7CFF", isFocusTime: true, hint: "IDEs")
        context.insert(CategoryRecord(code, sortOrder: 0))
        let renamed = CategoryDefinition(key: "email", name: "收件箱", colorHex: "#5C6BC0", hint: "Mail clients")
        context.insert(CategoryRecord(renamed, sortOrder: 1))
        try context.save()

        let service = ClassificationService(modelContext: context, ai: FakeAI(answer: .init(categoryKey: "code", confidence: .high)))
        #expect(service.category("code").name == "代码")
        #expect(service.category("email").name == "收件箱")
    }

    @Test func unknownAppGoesToAIAndBackfillsPendingSegments() async {
        let ai = FakeAI(answer: .init(categoryKey: "design", confidence: .high))
        let service = ClassificationService(modelContext: context, ai: ai)
        let unknown = ActivityContext(bundleID: "com.example.Unknown", appName: "Unknown")

        let first = service.classify(unknown)
        #expect(first.categoryKey == CategoryDefinition.uncategorizedKey)
        #expect(first.source == .pending)
        let segment = ActivitySegment(context: unknown, start: .now, categoryKey: first.categoryKey, source: first.source)
        context.insert(segment)

        // A second sighting before the answer arrives doesn't queue a duplicate call.
        _ = service.classify(unknown)
        await waitForQueue(service)

        #expect(ai.calls == 1)
        #expect(segment.categoryKey == "design")
        #expect(segment.classificationSource == .ai)
        #expect(service.classify(unknown) == ("design", .ai))
        #expect(ai.calls == 1)
    }

    @Test func userRuleReclassifiesHistoryButNotManualEdits() {
        let service = ClassificationService(modelContext: context, ai: FakeAI(answer: .init(categoryKey: "code", confidence: .high)))
        let youtube = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://youtube.com/watch?v=1")
        let auto = ActivitySegment(context: youtube, start: .now, categoryKey: "entertainment", source: .builtin)
        let manual = ActivitySegment(context: youtube, start: .now, categoryKey: "personal", source: .manual)
        context.insert(auto)
        context.insert(manual)

        service.addRule(field: .domain, pattern: "youtube.com", categoryKey: "learning")
        #expect(auto.categoryKey == "learning")
        #expect(auto.classificationSource == .rule)
        #expect(manual.categoryKey == "personal")

        service.deleteRule(service.userRules[0])
        #expect(auto.categoryKey == "entertainment")
        #expect(auto.classificationSource == .builtin)
    }

    // MARK: 猜测降级

    @Test func withoutAModelUnknownActivityIsGuessed() {
        let service = ClassificationService(modelContext: context, ai: NoModel())
        let app = ActivityContext(bundleID: "com.example.NotInstalled", appName: "Mystery")
        #expect(service.classify(app) == ("miscellaneous", .guess))
        // 认识的应用照旧走规则。
        #expect(service.classify(ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")) == ("code", .builtin))
    }

    @Test func failedModelCallsFallBackToAGuess() async {
        let service = ClassificationService(modelContext: context, ai: FailingModel())
        let app = ActivityContext(bundleID: "com.example.NotInstalled", appName: "Mystery")
        let first = service.classify(app)
        #expect(first.source == .pending)
        let segment = ActivitySegment(context: app, start: .now, categoryKey: first.categoryKey, source: first.source)
        context.insert(segment)
        await waitForQueue(service)

        #expect(segment.categoryKey == "miscellaneous")
        #expect(segment.classificationSource == .guess)
        // 重试之前不会再问一遍。
        #expect(service.classify(app) == ("miscellaneous", .guess))
    }

    @Test func guessesAreReplacedOnceAModelIsChosen() async {
        let router = AICoordinator(model: NoModel())
        let service = ClassificationService(modelContext: context, ai: router)
        let unknown = ActivityContext(bundleID: "com.example.Unknown", appName: "Unknown")
        let waiting = ActivitySegment(context: unknown, start: .now,
                                      categoryKey: CategoryDefinition.uncategorizedKey, source: .pending)
        context.insert(waiting)

        // 之前积压下来、一直在等模型的，先就地换成猜测。
        service.retryPending()
        #expect(waiting.classificationSource == .guess)

        let ai = FakeAI(answer: .init(categoryKey: "design", confidence: .medium))
        router.use(ai)
        service.retryPending()
        #expect(service.aiAvailability == .available)
        await waitForQueue(service)

        #expect(ai.calls == 1)
        #expect(waiting.categoryKey == "design")
        #expect(waiting.classificationSource == .ai)
    }

    @Test func maintenanceLetsRulesReplaceGuesses() {
        let service = ClassificationService(modelContext: context, ai: NoModel())
        let finder = ActivitySegment(context: ActivityContext(bundleID: "com.apple.finder", appName: "Finder"),
                                     start: .now, categoryKey: "miscellaneous", source: .guess)
        let unknown = ActivitySegment(context: ActivityContext(bundleID: "com.example.Unknown", appName: "Unknown"),
                                      start: .now, categoryKey: "miscellaneous", source: .guess)
        context.insert(finder)
        context.insert(unknown)
        Maintenance.run(modelContext: context, classifier: service)
        #expect(finder.categoryKey == "utility")
        #expect(finder.classificationSource == .builtin)
        #expect(unknown.classificationSource == .guess)
    }

    @Test func unknownSitesGoToTheModelNotTheBrowserRule() async {
        let ai = FakeAI(answer: .init(categoryKey: "research", confidence: .high))
        let service = ClassificationService(modelContext: context, ai: ai)
        let site = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://example.org/paper")
        #expect(service.classify(site) == (CategoryDefinition.uncategorizedKey, .pending))
        await waitForQueue(service)
        #expect(service.classify(site) == ("research", .ai))
        // 认识的和没有网址的标签页照旧走内置规则。
        #expect(service.classify(ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome",
                                                 url: "https://github.com/a")) == ("code", .builtin))
        #expect(service.classify(ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome",
                                                 url: "chrome://newtab/")) == ("browsing", .builtin))
        // 用户给浏览器本身建的规则仍然管所有标签页。
        service.addRule(field: .bundleID, pattern: "com.google.Chrome", categoryKey: "personal")
        #expect(service.classify(site) == ("personal", .rule))
    }

    @Test func maintenanceSendsSitesFiledAsBrowsingToTheModel() {
        let service = ClassificationService(modelContext: context, ai: NoModel())
        let shop = ActivitySegment(context: ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome",
                                                            url: "https://shop.example.com/"),
                                   start: .now, categoryKey: "browsing", source: .builtin)
        let newTab = ActivitySegment(context: ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome"),
                                     start: .now, categoryKey: "browsing", source: .builtin)
        context.insert(shop)
        context.insert(newTab)
        Maintenance.run(modelContext: context, classifier: service)
        #expect(shop.categoryKey == "shopping")
        #expect(shop.classificationSource == .guess)
        #expect(newTab.classificationSource == .builtin)
    }
}
