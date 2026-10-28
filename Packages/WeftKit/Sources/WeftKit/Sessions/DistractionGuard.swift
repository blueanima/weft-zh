import AppKit
import Foundation
import Observation

public struct DistractionIncident: Equatable, Sendable {
    public var context: ActivityContext
    public var category: CategoryDefinition

    public var displayName: String { context.domain ?? context.appName }
}

/// During a focus session, interrupts the user once they've lingered on a distracting
/// category for `refocusThresholdSeconds`.
@MainActor
@Observable
public final class DistractionGuard {
    public private(set) var incident: DistractionIncident? {
        didSet { if oldValue != incident { onIncidentChange?(incident) } }
    }
    public private(set) var disabledForSession = false

    /// Called when the overlay should appear (non-nil) or go away (nil).
    @ObservationIgnored public var onIncidentChange: ((DistractionIncident?) -> Void)?
    /// Asks the tracker for another sample after the given seconds; samples are event-driven,
    /// so nothing else would arrive when the threshold passes.
    @ObservationIgnored public var requestRecheck: ((TimeInterval) -> Void)?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let sessions: SessionEngine
    @ObservationIgnored private let notifier: any NotificationPosting
    @ObservationIgnored private var dwell: (key: String, since: Date)?
    @ObservationIgnored private var triggeredKey: String?
    /// Where "回到工作" returns to.
    @ObservationIgnored private var lastWorkBundleID: String?

    public init(preferences: Preferences, sessions: SessionEngine, notifier: any NotificationPosting) {
        self.preferences = preferences
        self.sessions = sessions
        self.notifier = notifier
    }

    public func sessionStarted() {
        disabledForSession = false
        dwell = nil
        triggeredKey = nil
        incident = nil
    }

    public func handle(_ sample: TrackerSample) {
        // Glancing at Weft (e.g. the menu bar) must not count as leaving the distraction.
        if sample.isOwnApp { return }
        if let context = sample.context, sample.category?.blockInFocus == false {
            lastWorkBundleID = context.bundleID
        }
        guard preferences.blockerEnabled, !disabledForSession, sessions.active?.kind == .focus,
              let context = sample.context, let category = sample.category, category.blockInFocus,
              !preferences.blockerAllowList.contains(context.classificationKey)
        else {
            dwell = nil
            triggeredKey = nil
            incident = nil
            return
        }

        let key = context.classificationKey
        if dwell?.key != key {
            dwell = (key, sample.date)
            triggeredKey = nil
            requestRecheck?(TimeInterval(preferences.refocusThresholdSeconds) + 0.5)
        }
        guard triggeredKey != key, let since = dwell?.since,
              sample.date.timeIntervalSince(since) >= TimeInterval(preferences.refocusThresholdSeconds)
        else { return }

        triggeredKey = key
        sessions.recordDistraction()
        let incident = DistractionIncident(context: context, category: category)
        switch preferences.blockerStyle {
        case .overlay:
            self.incident = incident
        case .notification:
            notifier.post(.distraction, title: "分心了？",
                          body: "\(incident.displayName) 属于\(category.name)。你正在专注时段中。")
        }
    }

    /// Hides the distracting app and brings back the last app used for work.
    public func backToWork() {
        let distracting = incident?.context.bundleID ?? dwell.map { String($0.key.split(separator: "|")[0]) }
        if let distracting {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: distracting) { app.hide() }
        }
        if let lastWorkBundleID, lastWorkBundleID != distracting {
            NSRunningApplication.runningApplications(withBundleIdentifier: lastWorkBundleID).first?.activate()
        }
        incident = nil
    }

    /// Never block this app/site again.
    public func notADistraction() {
        let key = incident?.context.classificationKey ?? dwell?.key
        if let key, !preferences.blockerAllowList.contains(key) {
            preferences.blockerAllowList.append(key)
        }
        incident = nil
    }

    public func disableForSession() {
        disabledForSession = true
        incident = nil
    }

    /// Dismiss without hiding anything; the blocker won't fire again for this app/site
    /// until the user leaves and comes back.
    public func ignore() {
        incident = nil
    }
}
