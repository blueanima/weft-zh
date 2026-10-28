import Foundation
import Observation
import SwiftData

/// Rules first, cached model answers second, the on-device model last. Model calls run one
/// at a time in the background; segments stay `pending` until their answer arrives.
@MainActor
@Observable
public final class ClassificationService {
    public private(set) var categories: [CategoryDefinition] = []
    public private(set) var userRules: [UserRule] = []
    public private(set) var aiAvailability: AIAvailability
    /// Number of distinct apps/sites waiting for the model.
    public private(set) var queuedCount = 0

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let ai: any AIClassifying
    @ObservationIgnored private var engine = RuleEngine(rules: BuiltinRules.all)
    @ObservationIgnored private var cache: [String: AIClassification] = [:]
    @ObservationIgnored private var queue: [(key: String, context: ActivityContext)] = []
    @ObservationIgnored private var failedKeys: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var categoryIndex: [String: CategoryDefinition] = [:]

    public init(modelContext: ModelContext, ai: any AIClassifying = FoundationModelsClassifier()) {
        self.modelContext = modelContext
        self.ai = ai
        aiAvailability = ai.availability()
        seedCategoriesIfNeeded()
        reloadCategories()
        reloadRules()
        loadCache()
    }

    // MARK: Categories

    public func category(_ key: String) -> CategoryDefinition {
        categoryIndex[key] ?? categoryIndex[CategoryDefinition.uncategorizedKey]
            ?? CategoryDefinition.defaults.last!
    }

    public var categoryLookup: [String: CategoryDefinition] { categoryIndex }

    public func reloadCategories() {
        let records = (try? modelContext.fetch(FetchDescriptor<CategoryRecord>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        categories = records.map(\.definition)
        categoryIndex = Dictionary(categories.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func updateCategory(_ definition: CategoryDefinition) {
        let key = definition.key
        guard let record = try? modelContext.fetch(FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.key == key })).first
        else { return }
        record.name = definition.name
        record.colorHex = definition.colorHex
        record.isFocusTime = definition.isFocusTime
        record.isMeeting = definition.isMeeting
        record.blockInFocus = definition.blockInFocus
        record.isDoNotTrack = definition.isDoNotTrack
        record.hint = definition.hint
        try? modelContext.save()
        reloadCategories()
    }

    private func seedCategoriesIfNeeded() {
        let records = (try? modelContext.fetch(FetchDescriptor<CategoryRecord>())) ?? []
        let existing = Set(records.map(\.key))
        for (index, definition) in CategoryDefinition.defaults.enumerated() where !existing.contains(definition.key) {
            modelContext.insert(CategoryRecord(definition, sortOrder: index))
        }
        // 中文版升级：还挂着英文默认名的内置分类改成中文；用户自己改过名字的不动。
        for record in records {
            guard let english = CategoryDefinition.legacyEnglishNames[record.key],
                  record.name == english,
                  let definition = CategoryDefinition.defaults.first(where: { $0.key == record.key }),
                  definition.name != english else { continue }
            record.name = definition.name
            record.hint = definition.hint
        }
        try? modelContext.save()
    }

    // MARK: Classification

    public func classify(_ context: ActivityContext) -> (categoryKey: String, source: ClassificationSource) {
        if let rule = engine.match(context) {
            return (rule.categoryKey, rule.source == .user ? .rule : .builtin)
        }
        if let cached = cache[context.classificationKey] {
            return (cached.categoryKey, .ai)
        }
        enqueue(context)
        return (CategoryDefinition.uncategorizedKey, .pending)
    }

    public func confidence(forKey key: String) -> AIConfidence? {
        cache[key]?.confidence
    }

    public func refreshAvailability() {
        aiAvailability = ai.availability()
        if aiAvailability == .available { retryPending() }
    }

    /// Queue every app/site that is still waiting, e.g. after Apple Intelligence was enabled.
    public func retryPending() {
        failedKeys.removeAll()
        let pending = ClassificationSource.pending.rawValue
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.classificationSourceRaw == pending }))) ?? []
        for segment in segments { enqueue(segment.context) }
    }

    private func enqueue(_ context: ActivityContext) {
        let key = context.classificationKey
        guard aiAvailability == .available, !failedKeys.contains(key), !queue.contains(where: { $0.key == key })
        else { return }
        queue.append((key, context))
        queuedCount = queue.count
        if worker == nil {
            worker = Task { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while let next = queue.first {
            do {
                let result = try await ai.classify(next.context, categories: categories)
                store(result, forKey: next.key)
            } catch {
                failedKeys.insert(next.key)
            }
            queue.removeFirst()
            queuedCount = queue.count
        }
        worker = nil
    }

    private func store(_ result: AIClassification, forKey key: String) {
        cache[key] = result
        if let existing = try? modelContext.fetch(FetchDescriptor<AIClassificationRecord>(predicate: #Predicate { $0.key == key })).first {
            existing.categoryKey = result.categoryKey
            existing.confidenceRaw = result.confidence.rawValue
        } else {
            modelContext.insert(AIClassificationRecord(key: key, categoryKey: result.categoryKey, confidence: result.confidence))
        }
        let pending = ClassificationSource.pending.rawValue
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.classificationKey == key && $0.classificationSourceRaw == pending }
        ))) ?? []
        for segment in segments {
            segment.categoryKey = result.categoryKey
            segment.classificationSource = .ai
        }
        try? modelContext.save()
    }

    private func loadCache() {
        let records = (try? modelContext.fetch(FetchDescriptor<AIClassificationRecord>())) ?? []
        cache = Dictionary(records.map { ($0.key, AIClassification(categoryKey: $0.categoryKey, confidence: $0.confidence)) },
                           uniquingKeysWith: { a, _ in a })
    }

    // MARK: User corrections

    public func reloadRules() {
        userRules = (try? modelContext.fetch(FetchDescriptor<UserRule>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        engine = RuleEngine(rules: BuiltinRules.all + userRules.map(\.rule))
    }

    /// Creates (or replaces) a user rule and reapplies classification to past activity it covers.
    public func addRule(field: RuleField, pattern: String, categoryKey: String) {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        for existing in userRules where existing.field == field && existing.pattern.lowercased() == pattern.lowercased() {
            modelContext.delete(existing)
        }
        let rule = UserRule(field: field, pattern: pattern, categoryKey: categoryKey)
        modelContext.insert(rule)
        try? modelContext.save()
        reloadRules()
        reclassify(affectedBy: rule.rule)
    }

    public func deleteRule(_ rule: UserRule) {
        let matcher = rule.rule
        modelContext.delete(rule)
        try? modelContext.save()
        reloadRules()
        reclassify(affectedBy: matcher)
    }

    /// Changes a single segment without creating a rule.
    public func setManualCategory(_ categoryKey: String, for segment: ActivitySegment) {
        segment.categoryKey = categoryKey
        segment.classificationSource = .manual
        try? modelContext.save()
    }

    /// Reapplies classification to the segments `rule` could match. The predicate narrows the
    /// fetch in the store so this stays cheap with months of history; `matches` makes it exact.
    private func reclassify(affectedBy rule: Rule) {
        let manual = ClassificationSource.manual.rawValue
        let pattern = rule.pattern
        let predicate: Predicate<ActivitySegment>
        switch rule.field {
        case .bundleID:
            predicate = #Predicate { $0.classificationSourceRaw != manual && $0.bundleID.localizedStandardContains(pattern) }
        case .domain:
            predicate = #Predicate { $0.classificationSourceRaw != manual && $0.domain.flatMap { $0.localizedStandardContains(pattern) } == true }
        case .titleContains:
            predicate = #Predicate { $0.classificationSourceRaw != manual && $0.title.flatMap { $0.localizedStandardContains(pattern) } == true }
        case .urlContains:
            predicate = #Predicate { $0.classificationSourceRaw != manual && $0.url.flatMap { $0.localizedStandardContains(pattern) } == true }
        }
        let candidates = (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? []
        for segment in candidates where rule.matches(segment.context) {
            let (key, source) = classify(segment.context)
            segment.categoryKey = key
            segment.classificationSource = source
        }
        try? modelContext.save()
    }
}
