import Foundation
import Observation

public enum BlockerStyle: String, CaseIterable, Sendable, Identifiable {
    case overlay
    case notification

    public var id: String { rawValue }
}

/// User settings, persisted in UserDefaults and observable from both views and engines.
@MainActor
@Observable
public final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    // Tracking
    public var trackingPaused: Bool { didSet { save(trackingPaused, "trackingPaused") } }
    public var idleThresholdMinutes: Int { didSet { save(idleThresholdMinutes, "idleThresholdMinutes") } }
    public var stripTitles: Bool { didSet { save(stripTitles, "stripTitles") } }
    public var urlHostOnly: Bool { didSet { save(urlHostOnly, "urlHostOnly") } }
    public var excludedBundleIDs: [String] { didSet { save(excludedBundleIDs, "excludedBundleIDs") } }
    public var excludedDomains: [String] { didSet { save(excludedDomains, "excludedDomains") } }

    // Sessions
    public var defaultFocusMinutes: Int { didSet { save(defaultFocusMinutes, "defaultFocusMinutes") } }
    public var defaultMeetingMinutes: Int { didSet { save(defaultMeetingMinutes, "defaultMeetingMinutes") } }
    public var defaultBreakMinutes: Int { didSet { save(defaultBreakMinutes, "defaultBreakMinutes") } }
    public var fullScreenBreak: Bool { didSet { save(fullScreenBreak, "fullScreenBreak") } }

    // Break reminders and work hours
    public var breakRemindersEnabled: Bool { didSet { save(breakRemindersEnabled, "breakRemindersEnabled") } }
    public var breakReminderMinutes: Int { didSet { save(breakReminderMinutes, "breakReminderMinutes") } }
    public var snoozeMinutes: Int { didSet { save(snoozeMinutes, "snoozeMinutes") } }
    public var workHoursTarget: Double { didSet { save(workHoursTarget, "workHoursTarget") } }
    public var workHoursNotifications: Bool { didSet { save(workHoursNotifications, "workHoursNotifications") } }

    // Distraction blocker
    public var blockerEnabled: Bool { didSet { save(blockerEnabled, "blockerEnabled") } }
    public var blockerStyle: BlockerStyle { didSet { save(blockerStyle.rawValue, "blockerStyle") } }
    public var refocusThresholdSeconds: Int { didSet { save(refocusThresholdSeconds, "refocusThresholdSeconds") } }
    /// Classification keys the user marked as "not a distraction".
    public var blockerAllowList: [String] { didSet { save(blockerAllowList, "blockerAllowList") } }

    // AI engine
    public var aiProvider: AIProvider { didSet { save(aiProvider.rawValue, "aiProvider") } }
    public var deepSeekModel: String { didSet { save(deepSeekModel, "deepSeekModel") } }
    public var deepSeekBaseURL: String { didSet { save(deepSeekBaseURL, "deepSeekBaseURL") } }
    public var deepSeekThinking: Bool { didSet { save(deepSeekThinking, "deepSeekThinking") } }
    /// Kept in the Keychain rather than UserDefaults; the setter writes through.
    public var deepSeekAPIKey: String { didSet { Keychain.set(deepSeekAPIKey, for: Self.deepSeekKeyAccount) } }

    public var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }

    private static let deepSeekKeyAccount = "deepseek.apiKey"

    /// Snapshot handed to the classifier, which runs off the main actor.
    public var aiSettings: AISettings {
        AISettings(
            provider: aiProvider,
            deepSeek: DeepSeekConfig(
                apiKey: deepSeekAPIKey,
                baseURL: deepSeekBaseURL,
                model: deepSeekModel,
                thinking: deepSeekThinking
            )
        )
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "idleThresholdMinutes": 5,
            "defaultFocusMinutes": 25,
            "defaultMeetingMinutes": 30,
            "defaultBreakMinutes": 5,
            "fullScreenBreak": true,
            "breakRemindersEnabled": true,
            "breakReminderMinutes": 60,
            "snoozeMinutes": 10,
            "workHoursTarget": 8.0,
            "workHoursNotifications": true,
            "blockerEnabled": true,
            "blockerStyle": BlockerStyle.overlay.rawValue,
            "refocusThresholdSeconds": 10,
            "aiProvider": AIProvider.deepSeek.rawValue,
            "deepSeekModel": DeepSeekConfig.defaultModel,
            "deepSeekBaseURL": DeepSeekConfig.defaultBaseURL,
        ])
        trackingPaused = defaults.bool(forKey: "trackingPaused")
        idleThresholdMinutes = defaults.integer(forKey: "idleThresholdMinutes")
        stripTitles = defaults.bool(forKey: "stripTitles")
        urlHostOnly = defaults.bool(forKey: "urlHostOnly")
        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? []
        excludedDomains = defaults.stringArray(forKey: "excludedDomains") ?? []
        defaultFocusMinutes = defaults.integer(forKey: "defaultFocusMinutes")
        defaultMeetingMinutes = defaults.integer(forKey: "defaultMeetingMinutes")
        defaultBreakMinutes = defaults.integer(forKey: "defaultBreakMinutes")
        fullScreenBreak = defaults.bool(forKey: "fullScreenBreak")
        breakRemindersEnabled = defaults.bool(forKey: "breakRemindersEnabled")
        breakReminderMinutes = defaults.integer(forKey: "breakReminderMinutes")
        snoozeMinutes = defaults.integer(forKey: "snoozeMinutes")
        workHoursTarget = defaults.double(forKey: "workHoursTarget")
        workHoursNotifications = defaults.bool(forKey: "workHoursNotifications")
        blockerEnabled = defaults.bool(forKey: "blockerEnabled")
        blockerStyle = BlockerStyle(rawValue: defaults.string(forKey: "blockerStyle") ?? "") ?? .overlay
        refocusThresholdSeconds = defaults.integer(forKey: "refocusThresholdSeconds")
        blockerAllowList = defaults.stringArray(forKey: "blockerAllowList") ?? []
        aiProvider = AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .deepSeek
        deepSeekModel = defaults.string(forKey: "deepSeekModel") ?? DeepSeekConfig.defaultModel
        deepSeekBaseURL = defaults.string(forKey: "deepSeekBaseURL") ?? DeepSeekConfig.defaultBaseURL
        deepSeekThinking = defaults.bool(forKey: "deepSeekThinking")
        deepSeekAPIKey = Keychain.string(for: Self.deepSeekKeyAccount) ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    public func defaultMinutes(for kind: SessionKind) -> Int {
        switch kind {
        case .focus: defaultFocusMinutes
        case .meeting: defaultMeetingMinutes
        case .breakTime: defaultBreakMinutes
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
