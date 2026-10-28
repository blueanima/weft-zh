import Foundation
import SwiftData
import Testing
@testable import WeftKit

private final class DescribingAI: AIClassifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    var prompts: [String] { lock.withLock { _prompts } }

    func availability() -> AIAvailability { .available }
    func classify(_ context: ActivityContext, categories: [CategoryDefinition]) async throws -> AIClassification {
        AIClassification(categoryKey: "code", confidence: .high)
    }
    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String {
        lock.withLock { _prompts.append(facts) }
        return "Worked on Weft."
    }
}

struct TimeEntriesTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func seg(_ startMinute: Double, _ minutes: Double, _ bundleID: String, category: String = "code",
             title: String? = nil) -> ActivitySegment {
        let segment = ActivitySegment(context: ActivityContext(bundleID: bundleID, appName: bundleID, title: title),
                                      start: t0 + startMinute * 60, categoryKey: category, source: .builtin)
        segment.end = t0 + (startMinute + minutes) * 60
        return segment
    }

    @Test func interleavedWorkBecomesOverlappingStreams() {
        // Coding with research and chat in between: one stream per category, overlapping.
        let entries = TimeEntries.build([
            seg(0, 15, "terminal"), seg(15, 5, "browser", category: "research"), seg(20, 15, "xcode"),
            seg(35, 2, "slack", category: "messaging"), seg(37, 10, "browser", category: "research"), seg(47, 10, "terminal"),
        ])
        let byCategory = Dictionary(grouping: entries, by: \.categoryKey)
        #expect(byCategory["code"]?.count == 1)
        #expect(byCategory["research"]?.count == 1)
        let code = byCategory["code"]![0], research = byCategory["research"]![0]
        #expect(code.activeTime == 40 * 60)
        #expect(research.start < code.end && code.start < research.end)
    }

    @Test func gapsShorterThanHalfAnHourDoNotSplit() {
        let entries = TimeEntries.build([seg(0, 20, "xcode"), seg(45, 20, "xcode")])
        #expect(entries.count == 1)
        #expect(TimeEntries.build([seg(0, 20, "xcode"), seg(55, 20, "xcode")]).count == 2)
    }

    @Test func longStreamsAreSplitAfterTwoHours() {
        let entries = TimeEntries.build((0..<15).map { seg(Double($0) * 10, 10, "xcode") })
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.end.timeIntervalSince($0.start) <= 2 * 3600 })
    }

    @Test func briefActivityIsNotSignificant() {
        let entries = TimeEntries.build([seg(0, 30, "xcode"), seg(5, 3, "tv", category: "entertainment")])
        #expect(entries.count == 2)
        #expect(TimeEntries.significant(entries).map(\.categoryKey) == ["code"])
    }

    @Test func keyIsStableAsTheStreamGrows() {
        let before = TimeEntries.build([seg(0, 20, "xcode")])[0]
        let after = TimeEntries.build([seg(0, 20, "xcode"), seg(25, 20, "xcode")])[0]
        #expect(before.key == after.key)
    }

    @Test func factsUseCleanTitlesAndFallbackListsApps() {
        let entries = TimeEntries.build([
            seg(0, 10, "Google Chrome", title: "Pull request #12 - Google Chrome - weishu"),
            seg(10, 5, "iTerm2", title: "1. ✳ build-server"),
        ])
        #expect(entries[0].facts.contains("- Pull request #12\n"))
        #expect(entries[0].titles == ["Pull request #12", "build-server"])
        #expect(entries[0].fallbackDescription == "Google Chrome 和 iTerm2")
    }

    @Test func streamsCompleteHalfAnHourAfterTheirLastActivity() {
        let entry = TimeEntries.build([seg(0, 20, "xcode")])[0]
        #expect(!entry.isComplete(now: t0 + 40 * 60))
        #expect(entry.isComplete(now: t0 + 51 * 60))
    }

    @MainActor
    @Test func serviceDescribesFinishedStreamsOnceAndCaches() async throws {
        let container = try WeftSchema.makeContainer(inMemory: true)
        let ai = DescribingAI()
        let service = TimeEntryService(modelContext: container.mainContext, ai: ai)
        let entries = TimeEntries.build([seg(0, 20, "xcode"), seg(60, 20, "xcode")])
        let now = t0 + 90 * 60

        service.describe(entries, now: now)
        service.describe(entries, now: now)
        for _ in 0..<100 where service.description(for: entries[0]) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.description(for: entries[0]) == "Worked on Weft.")
        #expect(service.description(for: entries[1]) == nil)
        #expect(ai.prompts.count == 1)

        // A fresh service reads the stored description instead of asking again.
        let reloaded = TimeEntryService(modelContext: container.mainContext, ai: ai)
        #expect(reloaded.description(for: entries[0]) == "Worked on Weft.")
    }
}
