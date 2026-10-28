import Foundation

/// Minimal, storage-independent view of a segment for metric computation.
public struct SegmentSample: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var categoryKey: String
    public var bundleID: String
    public var appName: String
    public var domain: String?

    public init(start: Date, end: Date, categoryKey: String, bundleID: String, appName: String = "", domain: String? = nil) {
        self.start = start
        self.end = end
        self.categoryKey = categoryKey
        self.bundleID = bundleID
        self.appName = appName
        self.domain = domain
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

public extension SegmentSample {
    init(_ segment: ActivitySegment) {
        self.init(start: segment.start, end: segment.end, categoryKey: segment.categoryKey,
                  bundleID: segment.bundleID, appName: segment.appName, domain: segment.domain)
    }
}

public struct FocusScoreConfig: Sendable {
    /// Focus stretches at least this long count as deep work.
    public var deepWorkMinimum: TimeInterval = 25 * 60
    /// Non-focus interruptions up to this long don't break a focus stretch.
    public var interruptionTolerance: TimeInterval = 60
    /// Switches shorter than this are ignored (e.g. Cmd-Tab passing through an app).
    public var switchNoiseFloor: TimeInterval = 5
    /// Context switches per hour that are considered normal.
    public var freeSwitchesPerHour: Double = 12
    /// Below this much active time there is not enough data for a score.
    public var minimumActiveTime: TimeInterval = 15 * 60

    public init() {}
}

/// Everything the dashboards show for a span of time (usually one day).
public struct DayMetrics: Sendable {
    public var activeTime: TimeInterval = 0
    public var focusTime: TimeInterval = 0
    public var deepWorkTime: TimeInterval = 0
    /// The longest focus stretch of the day (short interruptions tolerated).
    public var longestFocusStretch: TimeInterval = 0
    public var meetingTime: TimeInterval = 0
    public var distractingTime: TimeInterval = 0
    public var contextSwitches = 0
    public var byCategory: [String: TimeInterval] = [:]
    public var byApp: [String: TimeInterval] = [:]
    public var byDomain: [String: TimeInterval] = [:]
    /// Active seconds per hour of the day (0–23).
    public var byHour: [Int: TimeInterval] = [:]
    public var score: FocusScore?

    public init() {}

    public var switchesPerHour: Double {
        activeTime > 0 ? Double(contextSwitches) / (activeTime / 3600) : 0
    }

    public static func compute(
        _ samples: [SegmentSample],
        categories: [String: CategoryDefinition],
        config: FocusScoreConfig = FocusScoreConfig(),
        calendar: Calendar = .current
    ) -> DayMetrics {
        let samples = samples.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var metrics = DayMetrics()
        let isFocus = { (key: String) in categories[key]?.isFocusTime ?? false }

        for sample in samples {
            let duration = sample.duration
            let category = categories[sample.categoryKey]
            metrics.activeTime += duration
            metrics.byCategory[sample.categoryKey, default: 0] += duration
            metrics.byApp[sample.appName.isEmpty ? sample.bundleID : sample.appName, default: 0] += duration
            if let domain = sample.domain { metrics.byDomain[domain, default: 0] += duration }
            if category?.isFocusTime == true { metrics.focusTime += duration }
            if category?.isMeeting == true { metrics.meetingTime += duration }
            if category?.isDistracting == true { metrics.distractingTime += duration }
            metrics.addToHours(sample, calendar: calendar)
        }

        metrics.contextSwitches = countSwitches(samples, noiseFloor: config.switchNoiseFloor)
        (metrics.deepWorkTime, metrics.longestFocusStretch) = focusStretches(samples, isFocus: isFocus, config: config)
        metrics.score = FocusScore.compute(metrics, config: config)
        return metrics
    }

    private mutating func addToHours(_ sample: SegmentSample, calendar: Calendar) {
        var cursor = sample.start
        while cursor < sample.end {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let hourEnd = hourStart.addingTimeInterval(3600)
            let sliceEnd = min(hourEnd, sample.end)
            byHour[calendar.component(.hour, from: cursor), default: 0] += sliceEnd.timeIntervalSince(cursor)
            cursor = sliceEnd
        }
    }

    /// A switch is moving to a different app or site, ignoring blips shorter than the noise floor.
    static func countSwitches(_ samples: [SegmentSample], noiseFloor: TimeInterval) -> Int {
        var switches = 0
        var previous: (bundleID: String, domain: String?)?
        for sample in samples where sample.duration >= noiseFloor {
            let current = (sample.bundleID, sample.domain)
            if let previous, previous.bundleID != current.0 || previous.domain != current.1 {
                switches += 1
            }
            previous = current
        }
        return switches
    }

    /// Sum of focus stretches that last at least `deepWorkMinimum`, and the longest stretch.
    /// Short non-focus interruptions are tolerated but don't count towards a stretch; idle
    /// gaps end it.
    static func focusStretches(_ samples: [SegmentSample], isFocus: (String) -> Bool,
                               config: FocusScoreConfig) -> (deepWork: TimeInterval, longest: TimeInterval) {
        var total: TimeInterval = 0
        var longest: TimeInterval = 0
        var stretch: TimeInterval = 0
        var interruption: TimeInterval = 0
        var lastEnd: Date?

        func flush() {
            if stretch >= config.deepWorkMinimum { total += stretch }
            longest = max(longest, stretch)
            stretch = 0
            interruption = 0
        }

        for sample in samples {
            if let lastEnd, sample.start.timeIntervalSince(lastEnd) > config.interruptionTolerance {
                flush()
            }
            if isFocus(sample.categoryKey) {
                stretch += sample.duration
                interruption = 0
            } else if stretch > 0 {
                interruption += sample.duration
                if interruption > config.interruptionTolerance { flush() }
            }
            lastEnd = sample.end
        }
        flush()
        return (total, longest)
    }
}

/// 0–100 score with its components exposed so the UI can explain it.
public struct FocusScore: Sendable, Equatable {
    public var value: Int
    /// Share of active time spent in focus categories (0–1).
    public var focusRatio: Double
    /// Share of active time spent in deep-work stretches (0–1).
    public var deepWorkRatio: Double
    /// Points deducted for switching more often than normal.
    public var switchPenalty: Double
    /// Points deducted for time in distracting categories.
    public var distractionPenalty: Double

    public var label: String { Self.label(for: value) }

    /// Same wording as Rize.
    public static func label(for value: Int) -> String {
        switch value {
        case 97...: "极佳"
        case 94...: "优秀"
        case 90...: "很好"
        case 80...: "良好"
        case 65...: "一般"
        case 50...: "平庸"
        case 25...: "较差"
        case 1...: "很差"
        default: "无评分"
        }
    }

    /// score = 100 × (0.5 × deep-work ratio + 0.5 × focus ratio) − switch penalty − distraction penalty
    ///
    /// Meetings are excluded from the denominator: a day full of meetings isn't unfocused,
    /// it just leaves less room for focus work.
    static func compute(_ metrics: DayMetrics, config: FocusScoreConfig) -> FocusScore? {
        let workTime = metrics.activeTime - metrics.meetingTime
        guard metrics.activeTime >= config.minimumActiveTime, workTime > 0 else { return nil }

        let focusRatio = min(1, metrics.focusTime / workTime)
        let deepRatio = min(1, metrics.deepWorkTime / workTime)
        let extraSwitches = max(0, metrics.switchesPerHour - config.freeSwitchesPerHour)
        let switchPenalty = min(20, extraSwitches * 0.75)
        let distractionPenalty = min(30, metrics.distractingTime / workTime * 60)

        let raw = 100 * (0.5 * deepRatio + 0.5 * focusRatio) - switchPenalty - distractionPenalty
        return FocusScore(
            value: Int(max(0, min(100, raw)).rounded()),
            focusRatio: focusRatio,
            deepWorkRatio: deepRatio,
            switchPenalty: switchPenalty,
            distractionPenalty: distractionPenalty
        )
    }
}
