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
}
