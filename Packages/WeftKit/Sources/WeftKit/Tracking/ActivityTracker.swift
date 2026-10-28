import AppKit
import Foundation
import Observation
import SwiftData

/// One observation of the tracker, broadcast to sessions, break reminders and the blocker.
public struct TrackerSample: Sendable {
    public var date: Date
    public var context: ActivityContext?
    public var category: CategoryDefinition?
    /// True when the user is away (idle past the threshold, asleep, locked or paused).
    public var isAway: Bool
    /// The user is looking at Weft itself. That time isn't recorded, but it isn't
    /// time away either.
    public var isOwnApp = false
}

/// Records what the user is doing as `ActivitySegment`s. Event-driven to save power: it samples
/// when the frontmost app, its focused window or that window's title changes, plus a slow
/// heartbeat, a one-shot timer for when the user would count as idle, and a gentle check for
/// their return while away. Nothing runs on a fixed short interval.
@MainActor
@Observable
public final class ActivityTracker {
    public private(set) var current: ActivityContext?
    public private(set) var currentCategory: CategoryDefinition?
    public private(set) var isSuspendedBySystem = false

    /// Keeps the open segment's end and time-based features (work hours, break reminders)
    /// up to date between events.
    @ObservationIgnored public var heartbeat: TimeInterval = 60
    /// While away, how often to check whether the user is back.
    @ObservationIgnored public var awayCheckInterval: TimeInterval = 10
    @ObservationIgnored private var listeners: [(TrackerSample) -> Void] = []
    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let classifier: ClassificationService
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let urlProvider: BrowserURLProvider
    @ObservationIgnored private var machine = TrackingStateMachine()
    @ObservationIgnored private var openSegment: ActivitySegment?
    @ObservationIgnored private let events = WindowEventObserver()
    @ObservationIgnored private var throttle = TitleChangeThrottle()
    @ObservationIgnored private var deferredTitle: (app: String, task: Task<Void, Never>)?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var nextWake: Date?
    @ObservationIgnored private var isSampling = false
    @ObservationIgnored private var needsSample = false
    @ObservationIgnored private var hadAccessibility = false
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var browserCache: (bundleID: String, title: String?, result: BrowserURLResult)?

    public init(modelContext: ModelContext, classifier: ClassificationService, preferences: Preferences,
                urlProvider: BrowserURLProvider = BrowserURLProvider()) {
        self.modelContext = modelContext
        self.classifier = classifier
        self.preferences = preferences
        self.urlProvider = urlProvider
    }

    public func addListener(_ listener: @escaping (TrackerSample) -> Void) {
        listeners.append(listener)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        machine.maxTickGap = heartbeat * 2.5
        observeSystemEvents()
        observePauseSetting()
        events.onEvent = { [weak self] event in self?.handle(event) }
        events.start()
        hadAccessibility = SystemProbe.isAccessibilityTrusted
        sampleSoon()
    }

    public func stop() {
        isRunning = false
        wakeTask?.cancel()
        wakeTask = nil
        deferredTitle?.task.cancel()
        deferredTitle = nil
        events.stop()
        apply(machine.suspend(at: .now), category: nil)
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    /// Asks for a sample after `seconds`, e.g. for the distraction blocker to re-check.
    public func requestSample(after seconds: TimeInterval) {
        scheduleWake(at: Date().addingTimeInterval(seconds))
    }

    // MARK: Events and scheduling

    private func handle(_ event: WindowEventObserver.Event) {
        switch event {
        case .appActivated, .windowChanged:
            if let deferred = deferredTitle {
                deferred.task.cancel()
                throttle.cancelPending(app: deferred.app)
                deferredTitle = nil
            }
            sampleSoon()
        case .titleChanged(let app):
            switch throttle.titleChanged(app: app, at: .now) {
            case .handleNow:
                sampleSoon()
            case .ignore:
                break
            case .deferUntil(let date):
                // A noisy app (e.g. a terminal spinner): stop listening until `date`, then
                // read the latest title once.
                events.muteTitle()
                let task = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                    guard !Task.isCancelled, let self else { return }
                    self.throttle.deferredHandled(app: app, at: .now)
                    self.deferredTitle = nil
                    self.events.unmuteTitle()
                    self.sampleSoon()
                }
                deferredTitle = (app, task)
            }
        }
    }

    /// Samples now, or right after the sample in progress.
    private func sampleSoon() {
        guard isRunning else { return }
        if isSampling {
            needsSample = true
            return
        }
        isSampling = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                self.needsSample = false
                await self.tick()
            } while self.needsSample
            self.isSampling = false
        }
    }

    /// Wakes at `date` unless an earlier wake is already scheduled.
    private func scheduleWake(at date: Date) {
        guard isRunning else { return }
        if let nextWake, wakeTask != nil, nextWake <= date { return }
        nextWake = date
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.wakeTask = nil
            self.nextWake = nil
            self.sampleSoon()
        }
    }

    /// Resumes immediately when tracking is unpaused, without polling the setting.
    private func observePauseSetting() {
        withObservationTracking {
            _ = preferences.trackingPaused
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.sampleSoon()
                self?.observePauseSetting()
            }
        }
    }

    // MARK: Sampling

    private func tick() async {
        guard !preferences.trackingPaused, !isSuspendedBySystem else {
            // Paused or asleep: nothing to do until the setting or the system changes.
            suspend()
            return
        }
        let trusted = SystemProbe.isAccessibilityTrusted
        if trusted && !hadAccessibility { events.refresh() }
        hadAccessibility = trusted
        let idleSeconds = SystemProbe.secondsSinceLastInput
        let isOwnApp = SystemProbe.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        var context = isOwnApp ? nil : await captureContext()
        // Pausing or sleeping may have happened while we were waiting on the browser.
        guard !preferences.trackingPaused, !isSuspendedBySystem else {
            suspend()
            return
        }

        var category: CategoryDefinition?
        var classification: (categoryKey: String, source: ClassificationSource)?
        if let captured = context {
            let result = classifier.classify(captured)
            let definition = classifier.category(result.categoryKey)
            if definition.isDoNotTrack {
                context = nil
            } else {
                classification = result
                category = definition
            }
        }

        let now = Date()
        machine.idleThreshold = TimeInterval(preferences.idleThresholdMinutes * 60)
        let effects = machine.tick(now: now, context: context, idleSeconds: idleSeconds,
                                   idleExempt: category?.isMeeting ?? false)
        apply(effects, category: classification)

        let isAway = isOwnApp ? idleSeconds >= machine.idleThreshold : machine.current == nil
        if isOwnApp {
            // Keep showing what the user was doing before opening Weft (e.g. the menu bar
            // popover), unless they've gone idle in the meantime.
            if isAway { current = nil; currentCategory = nil }
            broadcast(TrackerSample(date: now, context: nil, category: nil, isAway: isAway, isOwnApp: true))
        } else {
            current = machine.current == nil ? nil : context
            currentCategory = machine.current == nil ? nil : category
            broadcast(TrackerSample(date: now, context: current, category: currentCategory, isAway: isAway))
        }

        if now.timeIntervalSince(lastSave) > 30 {
            try? modelContext.save()
            lastSave = now
        }

        // Next wake: the heartbeat, the moment the user would count as idle, or — while
        // away — a check for their return.
        var next = now.addingTimeInterval(heartbeat)
        if isAway {
            next = now.addingTimeInterval(awayCheckInterval)
        } else if !(category?.isMeeting ?? false) {
            let untilIdle = machine.idleThreshold - idleSeconds
            next = min(next, now.addingTimeInterval(max(1, untilIdle + 1)))
        }
        scheduleWake(at: next)
    }

    /// Stops recording. While the user merely paused tracking, the last activity stays on
    /// display so resuming doesn't flash "离开"; sleep and screen lock clear it.
    private func suspend() {
        apply(machine.suspend(at: .now), category: nil)
        if isSuspendedBySystem {
            current = nil
            currentCategory = nil
        }
        broadcast(TrackerSample(date: .now, context: nil, category: nil, isAway: true))
    }

    private func captureContext() async -> ActivityContext? {
        guard let app = SystemProbe.frontmostApplication, let bundleID = app.bundleIdentifier,
              bundleID != "com.apple.loginwindow", bundleID != "com.apple.ScreenSaver.Engine",
              !preferences.excludedBundleIDs.contains(bundleID) else { return nil }

        // A terminal's animated status glyph ("✳ ", "◐ ") isn't a change of activity.
        var title = SystemProbe.focusedWindowTitle(pid: app.processIdentifier).map(ActivityBlock.stripStatusPrefix)
        var url: String?

        if BrowserURLScripts.isSupported(bundleID) {
            switch await browserURL(bundleID: bundleID, title: title) {
            case .privateWindow: return nil
            case .url(let value): url = ActivityContext.isWebURL(value) ? value : nil
            case .unavailable: break
            }
        }

        let domain = url.flatMap(ActivityContext.domain(from:))
        if let domain, preferences.excludedDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
            return nil
        }
        if preferences.urlHostOnly { url = url.map(ActivityContext.hostOnly) }
        if preferences.stripTitles { title = nil }

        return ActivityContext(bundleID: bundleID, appName: app.localizedName ?? bundleID,
                               title: title, url: url, domain: domain)
    }

    /// Asks the browser only when the app or tab title changed; switching tabs or navigating
    /// changes the title, so there's no need to ask on a timer.
    private func browserURL(bundleID: String, title: String?) async -> BrowserURLResult {
        if let cache = browserCache, cache.bundleID == bundleID, cache.title == title {
            return cache.result
        }
        let result = await urlProvider.currentURL(bundleID: bundleID)
        browserCache = (bundleID, title, result)
        return result
    }

    private func apply(_ effects: [TrackerEffect], category: (categoryKey: String, source: ClassificationSource)?) {
        for effect in effects {
            switch effect {
            case .open(let context, let date):
                let segment = ActivitySegment(
                    context: context, start: date,
                    categoryKey: category?.categoryKey ?? CategoryDefinition.uncategorizedKey,
                    source: category?.source ?? .pending
                )
                modelContext.insert(segment)
                openSegment = segment
            case .extend(let date):
                openSegment?.end = date
            case .close(let date):
                guard let segment = openSegment else { continue }
                segment.end = max(segment.start, date)
                // Drop sub-second blips from Cmd-Tab and the like.
                if segment.duration < 1 { modelContext.delete(segment) }
                openSegment = nil
                try? modelContext.save()
            }
        }
    }

    private func broadcast(_ sample: TrackerSample) {
        for listener in listeners { listener(sample) }
    }

    // MARK: Sleep, lock and session switching

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        let pauses: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        let resumes: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in pauses {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSuspendedBySystem = true
                    self?.suspend()
                }
            }
            observers.append((center, token))
        }
        for (center, name) in resumes {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSuspendedBySystem = false
                    self?.sampleSoon()
                }
            }
            observers.append((center, token))
        }
    }
}
