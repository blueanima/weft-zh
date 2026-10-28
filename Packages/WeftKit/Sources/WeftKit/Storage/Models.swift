import Foundation
import SwiftData

public enum ClassificationSource: String, Codable, Sendable {
    /// Matched a built-in rule.
    case builtin
    /// Matched a rule the user created.
    case rule
    /// Classified by the on-device model.
    case ai
    /// Waiting for the model (or the model is unavailable).
    case pending
    /// The user changed this one segment by hand; never reclassified automatically.
    case manual
}

@Model
public final class ActivitySegment {
    #Index<ActivitySegment>([\.start], [\.classificationKey])

    public var start: Date
    public var end: Date
    public var bundleID: String
    public var appName: String
    public var title: String?
    public var url: String?
    public var domain: String?
    public var categoryKey: String
    public var classificationSourceRaw: String
    public var classificationKey: String

    public init(context: ActivityContext, start: Date, categoryKey: String, source: ClassificationSource) {
        self.start = start
        self.end = start
        self.bundleID = context.bundleID
        self.appName = context.appName
        self.title = context.title
        self.url = context.url
        self.domain = context.domain
        self.categoryKey = categoryKey
        self.classificationSourceRaw = source.rawValue
        self.classificationKey = context.classificationKey
    }

    public var classificationSource: ClassificationSource {
        get { ClassificationSource(rawValue: classificationSourceRaw) ?? .pending }
        set { classificationSourceRaw = newValue.rawValue }
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public var context: ActivityContext {
        ActivityContext(bundleID: bundleID, appName: appName, title: title, url: url, domain: domain)
    }
}

@Model
public final class CategoryRecord {
    @Attribute(.unique) public var key: String
    public var name: String
    public var colorHex: String
    public var isFocusTime: Bool
    public var isMeeting: Bool
    public var blockInFocus: Bool
    public var isDoNotTrack: Bool
    public var hint: String
    public var sortOrder: Int

    public init(_ definition: CategoryDefinition, sortOrder: Int) {
        key = definition.key
        name = definition.name
        colorHex = definition.colorHex
        isFocusTime = definition.isFocusTime
        isMeeting = definition.isMeeting
        blockInFocus = definition.blockInFocus
        isDoNotTrack = definition.isDoNotTrack
        hint = definition.hint
        self.sortOrder = sortOrder
    }

    public var definition: CategoryDefinition {
        CategoryDefinition(
            key: key, name: name, colorHex: colorHex, isFocusTime: isFocusTime, isMeeting: isMeeting,
            blockInFocus: blockInFocus, isDoNotTrack: isDoNotTrack, hint: hint
        )
    }
}

@Model
public final class UserRule {
    public var fieldRaw: String
    public var pattern: String
    public var categoryKey: String
    public var createdAt: Date

    public init(field: RuleField, pattern: String, categoryKey: String) {
        fieldRaw = field.rawValue
        self.pattern = pattern
        self.categoryKey = categoryKey
        createdAt = .now
    }

    public var field: RuleField { RuleField(rawValue: fieldRaw) ?? .bundleID }

    public var rule: Rule {
        Rule(field: field, pattern: pattern, categoryKey: categoryKey, source: .user)
    }
}

@Model
public final class AIClassificationRecord {
    @Attribute(.unique) public var key: String
    public var categoryKey: String
    public var confidenceRaw: String
    public var createdAt: Date

    public init(key: String, categoryKey: String, confidence: AIConfidence) {
        self.key = key
        self.categoryKey = categoryKey
        confidenceRaw = confidence.rawValue
        createdAt = .now
    }

    public var confidence: AIConfidence { AIConfidence(rawValue: confidenceRaw) ?? .low }
}

public enum SessionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case focus
    case meeting
    case breakTime = "break"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .focus: "专注"
        case .meeting: "会议"
        case .breakTime: "休息"
        }
    }
}

@Model
public final class SessionRecord {
    #Index<SessionRecord>([\.start])

    public var kindRaw: String
    public var start: Date
    public var end: Date
    public var plannedDuration: TimeInterval
    public var focusScore: Int?
    public var focusPercent: Double?
    public var distractions: Int
    public var rating: Int?

    public init(kind: SessionKind, start: Date, end: Date, plannedDuration: TimeInterval) {
        kindRaw = kind.rawValue
        self.start = start
        self.end = end
        self.plannedDuration = plannedDuration
        distractions = 0
    }

    public var kind: SessionKind { SessionKind(rawValue: kindRaw) ?? .focus }
}

/// A generated description of a time entry, keyed by `TimeEntry.key`.
@Model
public final class TimeEntrySummary {
    @Attribute(.unique) public var key: String
    public var text: String
    public var createdAt: Date

    public init(key: String, text: String) {
        self.key = key
        self.text = text
        createdAt = .now
    }
}

public enum WeftSchema {
    public static let models: [any PersistentModel.Type] = [
        ActivitySegment.self, CategoryRecord.self, UserRule.self, AIClassificationRecord.self, SessionRecord.self,
        TimeEntrySummary.self,
    ]

    public static let folderName = "Weft"
    public static let storeName = "Weft.store"

    public static var dataFolder: URL {
        URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Store under `~/Library/Application Support/Weft/`.
    @MainActor
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: dataFolder.appending(path: storeName))
        }
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
