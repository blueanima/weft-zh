import Foundation
import Observation
import SwiftData

/// Writes a one-sentence description of each finished time entry with the on-device model,
/// one at a time in the background, and keeps them in the store.
@MainActor
@Observable
public final class TimeEntryService {
    public private(set) var descriptions: [String: String] = [:]

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let ai: any AIClassifying
    @ObservationIgnored private var queue: [(key: String, facts: String)] = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    public init(modelContext: ModelContext, ai: any AIClassifying) {
        self.modelContext = modelContext
        self.ai = ai
        let records = (try? modelContext.fetch(FetchDescriptor<TimeEntrySummary>())) ?? []
        descriptions = Dictionary(records.map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })
    }

    public func description(for entry: TimeEntry) -> String? {
        descriptions[entry.key]
    }

    /// Queues every finished entry that has no description yet.
    public func describe(_ entries: [TimeEntry], now: Date = .now) {
        guard ai.availability() == .available else { return }
        for entry in entries where entry.isComplete(now: now) {
            let key = entry.key
            guard descriptions[key] == nil, !failed.contains(key), !queue.contains(where: { $0.key == key }) else { continue }
            queue.append((key, entry.facts))
        }
        if worker == nil, !queue.isEmpty {
            worker = Task { [weak self] in await self?.drain() }
        }
    }

    /// Today's entries, for the periodic background pass.
    public func describeToday() {
        let start = Calendar.current.startOfDay(for: .now)
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.end > start }, sortBy: [SortDescriptor(\.start)]
        ))) ?? []
        describe(TimeEntries.significant(TimeEntries.build(segments)))
    }

    private func drain() async {
        // 中文版固定输出简体中文，不跟系统语言走。
        let language = "简体中文"
        while let next = queue.first {
            do {
                let text = try await ai.describeActivity(next.facts, language: language)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                descriptions[next.key] = text
                modelContext.insert(TimeEntrySummary(key: next.key, text: text))
                try? modelContext.save()
            } catch {
                failed.insert(next.key)
            }
            queue.removeFirst()
        }
        worker = nil
    }
}
