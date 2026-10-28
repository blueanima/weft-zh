import AppKit
import Observation
import WeftKit
import SwiftData

enum Page: String, CaseIterable, Identifiable {
    case today, reports, review, categories, rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .reports: "报告"
        case .review: "待确认"
        case .categories: "分类"
        case .rules: "规则"
        }
    }

    var symbol: String {
        switch self {
        case .today: "clock"
        case .reports: "chart.bar.xaxis"
        case .review: "questionmark.bubble"
        case .categories: "square.grid.2x2"
        case .rules: "list.bullet.rectangle"
        }
    }
}

/// Owns every long-lived service and wires them together.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let preferences = Preferences()
    let ai = FoundationModelsClassifier()
    let classifier: ClassificationService
    let tracker: ActivityTracker
    let sessions: SessionEngine
    let distractionGuard: DistractionGuard
    let timeEntries: TimeEntryService

    var page: Page = .today
    /// The day the Today page shows; Reports sets it to drill into a day.
    var day = Calendar.current.startOfDay(for: .now)
    /// Set by a view that has access to `openWindow`.
    @ObservationIgnored var openDashboard: (() -> Void)?
    var accessibilityGranted = SystemProbe.isAccessibilityTrusted

    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let breakReminder: BreakReminder
    @ObservationIgnored private let workHours: WorkHoursMonitor
    @ObservationIgnored private let overlays = OverlayController()

    init() {
        do {
            container = try WeftSchema.makeContainer()
        } catch {
            fatalError("无法打开 Weft 数据库：\(error)")
        }
        let context = container.mainContext
        classifier = ClassificationService(modelContext: context, ai: ai)
        Maintenance.run(modelContext: context, classifier: classifier)
        tracker = ActivityTracker(modelContext: context, classifier: classifier, preferences: preferences)
        sessions = SessionEngine(modelContext: context, classifier: classifier)
        distractionGuard = DistractionGuard(preferences: preferences, sessions: sessions, notifier: notifier)
        timeEntries = TimeEntryService(modelContext: context, ai: ai)
        breakReminder = BreakReminder(preferences: preferences, sessions: sessions, notifier: notifier)
        workHours = WorkHoursMonitor(preferences: preferences, notifier: notifier, modelContext: context)

        wire()
        notifier.requestAuthorization()
        tracker.start()
        classifier.retryPending()
        describeTimeEntriesPeriodically()
    }

    /// Describes finished time entries in the background so the timeline is ready when opened.
    private func describeTimeEntriesPeriodically() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.timeEntries.describeToday()
                try? await Task.sleep(for: .seconds(270))
            }
        }
    }

    private func wire() {
        tracker.addListener { [weak self] sample in
            guard let self else { return }
            breakReminder.handle(sample)
            workHours.handle(sample)
            distractionGuard.handle(sample)
            if !accessibilityGranted, SystemProbe.isAccessibilityTrusted { accessibilityGranted = true }
        }

        sessions.onStart = { [weak self] session in
            guard let self else { return }
            distractionGuard.sessionStarted()
            if session.kind == .breakTime, preferences.fullScreenBreak {
                overlays.showBreak(model: self)
            } else {
                overlays.hideBreak()
            }
        }

        sessions.onEnd = { [weak self] summary in
            guard let self else { return }
            overlays.hideBreak()
            guard summary.completed else { return }
            switch summary.kind {
            case .breakTime:
                notifier.post(.sessionEnded, title: "休息结束", body: "准备好继续了吗？")
            case .focus, .meeting:
                var body = "\(summary.kind.title)时段结束。"
                if let score = summary.score { body += "专注分 \(score.value)（\(score.label)）。" }
                if summary.distractions > 0 { body += "分心 \(summary.distractions) 次。" }
                notifier.post(.sessionEnded, title: "时段结束", body: body)
            }
        }

        distractionGuard.requestRecheck = { [weak self] seconds in
            self?.tracker.requestSample(after: seconds)
        }

        distractionGuard.onIncidentChange = { [weak self] incident in
            guard let self else { return }
            if incident != nil { overlays.showBlocker(model: self) } else { overlays.hideBlocker() }
        }

        notifier.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .startBreak: startSession(.breakTime)
            case .snooze: breakReminder.snooze()
            case .backToWork: distractionGuard.backToWork()
            case .notADistraction: distractionGuard.notADistraction()
            }
        }
    }

    func startSession(_ kind: SessionKind, minutes: Int? = nil) {
        sessions.start(kind, minutes: minutes ?? preferences.defaultMinutes(for: kind))
    }

    func refreshPermissions() {
        accessibilityGranted = SystemProbe.isAccessibilityTrusted
        tracker.requestSample(after: 0)
        classifier.refreshAvailability()
    }
}

extension AppModel {
    /// Shows `date` on the Today page.
    func showDay(_ date: Date = .now) {
        day = Calendar.current.startOfDay(for: date)
        page = .today
    }
}
