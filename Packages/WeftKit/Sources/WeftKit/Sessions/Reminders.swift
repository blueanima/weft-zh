import Foundation
import SwiftData

/// Reminds the user to take a break after a stretch of *actual* activity (time away from the
/// keyboard resets the stretch), rather than on a wall-clock timer.
@MainActor
public final class BreakReminder {
    private let preferences: Preferences
    private let sessions: SessionEngine
    private let notifier: any NotificationPosting
    private var streakStart: Date?
    private var nextReminder: Date?

    public init(preferences: Preferences, sessions: SessionEngine, notifier: any NotificationPosting) {
        self.preferences = preferences
        self.sessions = sessions
        self.notifier = notifier
    }

    public func handle(_ sample: TrackerSample) {
        if sample.isAway || sessions.active?.kind == .breakTime {
            streakStart = nil
            nextReminder = nil
            return
        }
        let streakStart = streakStart ?? sample.date
        self.streakStart = streakStart
        guard preferences.breakRemindersEnabled else { return }

        let due = nextReminder ?? streakStart.addingTimeInterval(TimeInterval(preferences.breakReminderMinutes * 60))
        guard sample.date >= due else { return }
        let minutes = Int(sample.date.timeIntervalSince(streakStart) / 60)
        notifier.post(.breakReminder, title: "该休息了",
                      body: "你已经连续工作 \(minutes) 分钟没有休息了。")
        snooze(from: sample.date)
    }

    public func snooze(from date: Date = .now) {
        nextReminder = date.addingTimeInterval(TimeInterval(preferences.snoozeMinutes * 60))
    }
}

/// Notifies once when today's tracked time reaches the work-hours target, and once more an
/// hour later as an overworking warning.
@MainActor
public final class WorkHoursMonitor {
    private let preferences: Preferences
    private let notifier: any NotificationPosting
    private var day: Date
    private var worked: TimeInterval
    private var lastSample: Date?
    private var notifiedTarget = false
    private var notifiedOvertime = false

    public init(preferences: Preferences, notifier: any NotificationPosting, modelContext: ModelContext) {
        self.preferences = preferences
        self.notifier = notifier
        let today = Calendar.current.startOfDay(for: .now)
        day = today
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.end > today }))) ?? []
        worked = segments.reduce(0) { $0 + $1.end.timeIntervalSince(max($1.start, today)) }
        let target = preferences.workHoursTarget * 3600
        notifiedTarget = worked >= target
        notifiedOvertime = worked >= target + 3600
    }

    public func handle(_ sample: TrackerSample) {
        let today = Calendar.current.startOfDay(for: sample.date)
        if today != day {
            day = today
            worked = 0
            notifiedTarget = false
            notifiedOvertime = false
        }
        defer { lastSample = sample.date }
        guard !sample.isAway, let lastSample else { return }
        // Samples arrive on events and a one-minute heartbeat; away time never counts.
        worked += min(sample.date.timeIntervalSince(lastSample), 90)

        guard preferences.workHoursNotifications else { return }
        let target = preferences.workHoursTarget * 3600
        if !notifiedTarget, worked >= target {
            notifiedTarget = true
            notifier.post(.workHours, title: "已达成工作时长目标",
                          body: "今天已记录 \(Self.format(worked))，可以考虑收尾了。")
        } else if !notifiedOvertime, worked >= target + 3600 {
            notifiedOvertime = true
            notifier.post(.workHours, title: "工作时间过长了",
                          body: "今天已记录 \(Self.format(worked))，已超出目标一小时。")
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}
