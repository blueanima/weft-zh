import Foundation
import SwiftData

/// Idempotent upkeep of stored data, run at launch.
@MainActor
public enum Maintenance {
    public static func run(modelContext: ModelContext, classifier: ClassificationService) {
        // 模型答过的、猜过的，遇到后来才有的规则（比如新版本内置的）要让位给规则。
        let ai = ClassificationSource.ai.rawValue
        let guessed = ClassificationSource.guess.rawValue
        let answered = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.classificationSourceRaw == ai || $0.classificationSourceRaw == guessed }
        ))) ?? []
        for segment in answered {
            let (key, source) = classifier.classify(segment.context)
            guard source == .builtin || source == .rule || (source == .ai && segment.classificationSource == .guess)
            else { continue }
            segment.categoryKey = key
            segment.classificationSource = source
        }

        // 旧版的内置浏览器规则会匹配所有标签页，于是不认识的网站全被记成了浏览网页。
        // 把它们当成新活动重新判一次：有规则就用规则，没有就交给模型，模型也不行就先猜。
        let builtin = ClassificationSource.builtin.rawValue
        let browsing = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.classificationSourceRaw == builtin && $0.categoryKey == "browsing" && $0.domain != nil }
        ))) ?? []
        for segment in browsing {
            let (key, source) = classifier.classify(segment.context)
            segment.categoryKey = key
            segment.classificationSource = source
        }
        try? modelContext.save()
    }
}
