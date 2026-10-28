import Foundation
import Testing
@testable import WeftKit

/// Runs the real on-device model against apps and sites the built-in rules don't know.
/// Opt in with `WEFT_AI_TESTS=1 swift test --filter FoundationModelsHarness`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WEFT_AI_TESTS"] != nil))
struct FoundationModelsHarness {
    let classifier = FoundationModelsClassifier()

    static let cases: [(ActivityContext, Set<String>)] = [
        (ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", title: "The Rust Programming Language - Ownership",
                         url: "https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html"), ["code", "learning", "documenting", "research"]),
        (ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", title: "Watch Live Football",
                         url: "https://www.espn.com/watch/"), ["entertainment"]),
        (ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", title: "Nike Air Max - Buy Now",
                         url: "https://www.nike.com/t/air-max"), ["shopping"]),
        (ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", title: "Inbox (3) - Zoho Mail",
                         url: "https://mail.zoho.com/zm/"), ["email"]),
        (ActivityContext(bundleID: "com.reincubate.camo", appName: "Camo", title: "Camo"), ["utility", "video_conferencing"]),
        (ActivityContext(bundleID: "com.hogbaysoftware.Bike", appName: "Bike", title: "Project outline.bike"), ["writing", "productivity", "documenting"]),
        (ActivityContext(bundleID: "com.supercell.clashroyale", appName: "Clash Royale"), ["gaming"]),
        (ActivityContext(bundleID: "com.apple.Safari", appName: "Safari", title: "什么是量子纠缠？ - 知乎",
                         url: "https://www.zhihu.com/question/1"), ["research", "learning", "social_media"]),
    ]

    @Test func availability() {
        #expect(classifier.availability() == .available)
    }

    /// Accuracy report rather than a strict per-case check: a few unknown native apps are
    /// genuinely ambiguous and end up in Review with low confidence anyway.
    @Test func accuracy() async throws {
        var hits = 0
        for (context, accepted) in Self.cases {
            let start = Date()
            let result = try await classifier.classify(context, categories: CategoryDefinition.defaults)
            let ok = accepted.contains(result.categoryKey)
            if ok { hits += 1 }
            print("[harness] \(ok ? "✓" : "✗") \(context.domain ?? context.appName) → \(result.categoryKey) (\(result.confidence.rawValue)) in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }
        print("[harness] accuracy \(hits)/\(Self.cases.count)")
        #expect(Double(hits) / Double(Self.cases.count) >= 0.75)
    }

    @Test func installedAppsUseAppStoreCategory() async throws {
        let xcodeLike = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")
        #expect(CategoryGuess.appStoreCategory(bundleID: xcodeLike.bundleID) == "developer-tools")
        let result = try await classifier.classify(xcodeLike, categories: CategoryDefinition.defaults)
        print("[harness] Xcode → \(result.categoryKey) (\(result.confidence.rawValue))")
        #expect(result.categoryKey == "code")
    }

    @Test func describesAStretchOfWork() async throws {
        let facts = """
            Time: 12:16–12:54, 36 minutes active
            Apps and websites: iTerm2 22m, github.com 6m, localhost 4m, claude.ai 2m, Xcode 2m
            Window titles, most time first:
            - 1. ✳ openrize-macos-swiftui-app
            - ActivityWatch/activitywatch: The best free and open-source automated time tracker
            - ssh build-server
            - Weft – DayView.swift
            - Rize alternatives for macOS
            """
        for language in ["English", "Chinese"] {
            let text = try await classifier.describeActivity(facts, language: language)
            print("[harness] \(language): \(text)")
            #expect(!text.isEmpty && text.count < 300)
        }
    }
}
