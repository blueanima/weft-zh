import Foundation

/// A stream of work in one category, e.g. "Code, 9:10–10:55". Streams of different
/// categories may overlap, because people work on several things at once. Each gets a
/// one-sentence description from the on-device model.
public struct TimeEntry: Identifiable {
    public var categoryKey: String
    /// Segments in time order.
    public var segments: [ActivitySegment]

    public var start: Date { segments[0].start }
    public var end: Date { segments.map(\.end).max() ?? start }
    public var activeTime: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    /// Stable as the stream grows, so descriptions can be cached by it.
    public var key: String { "\(categoryKey)-\(Int(start.timeIntervalSince1970))" }
    public var id: String { key }

    /// Apps and sites by time spent, most first.
    public var usage: [(name: String, bundleID: String, time: TimeInterval)] {
        var time: [String: (String, TimeInterval)] = [:]
        for segment in segments {
            let name = segment.domain ?? segment.appName
            time[name, default: (segment.bundleID, 0)].1 += segment.duration
        }
        return time.map { (name: $0.key, bundleID: $0.value.0, time: $0.value.1) }.sorted { $0.time > $1.time }
    }

    /// Cleaned window titles, the ones looked at longest first.
    public var titles: [String] {
        var time: [String: TimeInterval] = [:]
        for segment in segments {
            guard let title = segment.title.flatMap({ ActivityBlock.clean($0, appName: segment.appName) }) else { continue }
            time[title, default: 0] += segment.duration
        }
        return time.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Used when no model is available: "iTerm2、github.com 和 Xcode".
    public var fallbackDescription: String {
        let names = usage.prefix(3).map(\.name)
        switch names.count {
        case 0: return "活动"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: "、") + " 和 " + names[names.count - 1]
        }
    }

    /// A stream is finished once nothing could still join it.
    public func isComplete(now: Date, mergeGap: TimeInterval = TimeEntryConfig().mergeGap) -> Bool {
        now.timeIntervalSince(end) > mergeGap
    }

    /// What the model sees: apps, sites and the window titles looked at longest. Stays on
    /// the device.
    public var facts: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let apps = usage.prefix(6).map { "\($0.name) \(Int(($0.time / 60).rounded())) 分钟" }
        let titles = titles.prefix(12).map { "- \($0.prefix(90))" }
        return """
            时间：\(formatter.string(from: start))–\(formatter.string(from: end))，活跃 \(Int((activeTime / 60).rounded())) 分钟
            应用和网站：\(apps.joined(separator: "、"))
            窗口标题（按停留时长排序）：
            \(titles.isEmpty ? "（无）" : titles.joined(separator: "\n"))
            """
    }
}

public struct TimeEntryConfig: Sendable {
    /// Activity in the same category this close together belongs to one stream.
    public var mergeGap: TimeInterval = 30 * 60
    /// Streams are split once they would span longer than this.
    public var maxSpan: TimeInterval = 2 * 3600
    /// Streams with less activity than this are too small to show on the timeline.
    public var minActiveTime: TimeInterval = 10 * 60

    public init() {}
}

public enum TimeEntries {
    /// All streams of the day, including ones below `minActiveTime`; see `significant`.
    public static func build(_ segments: [ActivitySegment], config: TimeEntryConfig = TimeEntryConfig()) -> [TimeEntry] {
        var entries: [TimeEntry] = []
        for (category, members) in Dictionary(grouping: segments, by: \.categoryKey) {
            var current: TimeEntry?
            for segment in members.sorted(by: { $0.start < $1.start }) {
                if var stream = current,
                   segment.start.timeIntervalSince(stream.end) <= config.mergeGap,
                   segment.end.timeIntervalSince(stream.start) <= config.maxSpan {
                    stream.segments.append(segment)
                    current = stream
                } else {
                    if let stream = current { entries.append(stream) }
                    current = TimeEntry(categoryKey: category, segments: [segment])
                }
            }
            if let stream = current { entries.append(stream) }
        }
        return entries.sorted { $0.start < $1.start }
    }

    /// The streams worth showing on the timeline.
    public static func significant(_ entries: [TimeEntry], config: TimeEntryConfig = TimeEntryConfig()) -> [TimeEntry] {
        entries.filter { $0.activeTime >= config.minActiveTime }
    }
}
