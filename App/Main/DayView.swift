import Charts
import WeftKit
import SwiftData
import SwiftUI

struct DayView: View {
    @Environment(AppModel.self) private var model
    @State private var showCalendar = false

    var body: some View {
        @Bindable var model = model
        let day = model.day
        DayContent(day: day)
            .id(day)
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month().day()))
            .toolbar {
                ToolbarItemGroup {
                    Button { showCalendar = true } label: { Image(systemName: "calendar") }
                        .help("跳转到某一天")
                        .popover(isPresented: $showCalendar) {
                            DatePicker("日期", selection: Binding(
                                get: { model.day },
                                set: { model.day = Calendar.current.startOfDay(for: $0); showCalendar = false }
                            ), in: ...Date.now, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding()
                        }
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .help("前一天")
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("今天") { model.showDay() }
                        .disabled(Calendar.current.isDateInToday(day))
                        .keyboardShortcut("t", modifiers: .command)
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .help("后一天")
                        .disabled(Calendar.current.isDateInToday(day))
                        .keyboardShortcut(.rightArrow, modifiers: .command)
                }
            }
    }

    private func shift(_ days: Int) {
        model.day = Calendar.current.date(byAdding: .day, value: days, to: model.day) ?? model.day
    }
}

enum DayTab: String, CaseIterable, Identifiable {
    case timeline, breakdown, log

    var id: Self { self }

    var title: String {
        switch self {
        case .timeline: "时间线"
        case .breakdown: "分类与应用"
        case .log: "记录"
        }
    }
}

private struct DayContent: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]
    @Query private var sessions: [SessionRecord]
    /// The week before, to say how this day compares with a usual one.
    @Query private var previous: [ActivitySegment]
    @AppStorage("todayTab") private var tab: DayTab = .timeline
    private let day: Date
    private let dayEnd: Date

    init(day: Date) {
        self.day = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        dayEnd = end
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > day && $0.start < end }, sort: \.start)
        _sessions = Query(filter: #Predicate<SessionRecord> { $0.end > day && $0.start < end }, sort: \.start)
        let weekBefore = Calendar.current.date(byAdding: .day, value: -7, to: day) ?? day
        _previous = Query(filter: #Predicate<ActivitySegment> { $0.end > weekBefore && $0.start < day })
    }

    /// The seven days before, each cut off at the current time of day while the day being
    /// viewed is still going, so a morning isn't compared with whole days.
    private func baseline() -> PeriodSummary {
        let calendar = Calendar.current
        let elapsed = calendar.isDateInToday(day) ? Date.now.timeIntervalSince(day) : nil
        let days = (1...7).compactMap { offset -> DateInterval? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: day),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: elapsed.map { min(end, start.addingTimeInterval($0)) } ?? end)
        }
        return PeriodSummary(DayMetrics.daily(previous.map(SegmentSample.init), days: days,
                                              categories: model.classifier.categoryLookup))
    }

    var body: some View {
        let samples = segments.map { segment -> SegmentSample in
            var sample = SegmentSample(segment)
            sample.start = max(sample.start, day)
            sample.end = min(sample.end, dayEnd)
            return sample
        }
        let metrics = DayMetrics.compute(samples, categories: model.classifier.categoryLookup)
        let entries = TimeEntries.significant(TimeEntries.build(segments))

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if segments.isEmpty {
                    ContentUnavailableView("没有活动", systemImage: "clock",
                                           description: Text("这一天没有记录到任何活动。"))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    Overview(metrics: metrics, target: model.preferences.workHoursTarget * 3600,
                             baseline: baseline(), isToday: Calendar.current.isDateInToday(day))
                    DailyReview(day: day, metrics: metrics)
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("视图", selection: $tab) {
                            ForEach(DayTab.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        switch tab {
                        case .timeline:
                            DayTimeline(day: day, segments: segments, sessions: sessions) { tab = .log }
                        case .breakdown:
                            HStack(alignment: .top, spacing: 16) {
                                Card("分类") { CategoryBreakdown(metrics: metrics) }
                                Card("应用与网站") { AppBreakdown(samples: samples, total: metrics.activeTime) }
                            }
                        case .log:
                            ActivityList(segments: segments)
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                }
            }
            .padding(20)
        }
        // Describe finished entries of the day being viewed, including past days.
        .task(id: "\(entries.count)-\(entries.last?.key ?? "")") {
            model.timeEntries.describe(entries)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

// MARK: - Overview

/// The answer to "how did today go?": score, progress towards the target, and three
/// plain-language facts.
private struct Overview: View {
    let metrics: DayMetrics
    let target: TimeInterval
    let baseline: PeriodSummary
    let isToday: Bool
    @State private var showScoreDetails = false

    private var comparison: String { isToday ? "与平常此时相比" : "与 7 天平均相比" }

    /// Nil without a week of history to compare against.
    private func change(_ value: KeyPath<DayMetrics, TimeInterval>) -> Change? {
        baseline.perActiveDay(value).map { Change(metrics[keyPath: value], baseline: $0) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            Button { showScoreDetails = true } label: {
                ScoreRing(score: metrics.score, activeTime: metrics.activeTime, size: 112)
            }
            .buttonStyle(.plain)
            .help("专注分是怎么算的")
            .popover(isPresented: $showScoreDetails) { ScoreExplanation(score: metrics.score).padding() }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.duration(metrics.activeTime))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("已记录 / 目标 \(Format.duration(target))").foregroundStyle(.secondary)
                    if let change = change(\.activeTime) {
                        ChangeLabel(change: change, suffix: comparison).padding(.leading, 4)
                    }
                }
                GoalBar(metrics: metrics, target: target)
                HStack(spacing: 14) {
                    legend(GoalBar.focusColor, "专注", metrics.focusTime)
                    legend(GoalBar.meetingColor, "会议", metrics.meetingTime)
                    legend(GoalBar.otherColor, "其他", max(0, metrics.activeTime - metrics.focusTime - metrics.meetingTime - metrics.distractingTime))
                    legend(GoalBar.distractedColor, "分心", metrics.distractingTime)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 100)

            VStack(alignment: .leading, spacing: 12) {
                Fact(symbol: "brain.head.profile", title: "深度工作",
                     value: Format.duration(metrics.deepWorkTime), detail: "单段 25 分钟以上",
                     change: change(\.deepWorkTime), comparison: comparison)
                Fact(symbol: "timer", title: "最长专注",
                     value: Format.duration(metrics.longestFocusStretch), detail: "期间没有真正休息")
                Fact(symbol: "arrow.left.arrow.right", title: "切换",
                     value: switching.0, detail: switching.1)
            }
            .frame(width: 230, alignment: .leading)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }

    private var switching: (String, String) {
        guard metrics.activeTime >= 15 * 60 else { return ("\(metrics.contextSwitches) 次切换", "在应用与网站之间") }
        let perHour = metrics.switchesPerHour
        let label = perHour <= 12 ? "稳定" : perHour <= 25 ? "略有切换" : "被打断"
        return (label, "每小时 \(Int(perHour.rounded())) 次切换")
    }

    private func legend(_ color: Color, _ title: String, _ value: TimeInterval) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(Format.duration(value)).monospacedDigit()
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
    }
}

private struct Fact: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    var change: Change? = nil
    var comparison = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).foregroundStyle(.secondary)
                    Spacer()
                    Text(value).fontWeight(.medium).monospacedDigit()
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(detail).foregroundStyle(.tertiary)
                    Spacer()
                    if let change {
                        ChangeLabel(change: change, help: comparison)
                    }
                }
                .font(.caption)
            }
        }
        .font(.callout)
    }
}

private struct ScoreExplanation: View {
    let score: FocusScore?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("专注分是怎么算的").font(.headline)
            Text("100 ×（½ 深度工作占比 + ½ 专注占比）− 切换扣分 − 分心扣分。会议不计入。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let score {
                Divider()
                LabeledContent("专注占比", value: Format.percent(score.focusRatio))
                LabeledContent("深度工作占比（单段 ≥ 25 分钟）", value: Format.percent(score.deepWorkRatio))
                LabeledContent("切换扣分", value: String(format: "−%.0f", score.switchPenalty))
                LabeledContent("分心扣分", value: String(format: "−%.0f", score.distractionPenalty))
            } else {
                Text("至少需要 15 分钟的记录时间。").font(.callout)
            }
        }
        .frame(width: 340)
    }
}

// MARK: - Daily review

private struct DailyReview: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let metrics: DayMetrics
    @State private var text: String?
    @State private var error: String?
    @State private var isGenerating = false

    var body: some View {
        if text == nil, case .unavailable(let reason) = model.classifier.aiAvailability {
            // Nothing to act on here, so keep it out of the way.
            Label("每日回顾需要开启 AI 引擎。\(reason)", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").font(.title3).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 8) {
                if let text {
                    Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("生成这一天的简短回顾，并给出一个明天的建议。")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Spacer()
            if model.classifier.aiAvailability == .available {
                if isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Button(text == nil ? "回顾这一天" : "重新生成", action: generate)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.purple.opacity(0.08)))
    }

    private func generate() {
        isGenerating = true
        error = nil
        let facts = facts()
        Task {
            do {
                text = try await model.ai.summarize(facts)
            } catch {
                self.error = "无法生成回顾：\(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    /// Aggregates only — window titles and URLs never go into the prompt.
    private func facts() -> String {
        let categories = metrics.byCategory.sorted { $0.value > $1.value }.prefix(6)
            .map { "\(model.classifier.category($0.key).name) \(Format.duration($0.value))" }
        let apps = metrics.byApp.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) \(Format.duration($0.value))" }
        let sites = metrics.byDomain.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) \(Format.duration($0.value))" }
        let busiest = metrics.byHour.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) 点" }
        return """
            请用简体中文回答。
            日期：\(day.formatted(date: .complete, time: .omitted))
            记录时长：\(Format.duration(metrics.activeTime))（目标 \(Format.duration(model.preferences.workHoursTarget * 3600))）
            专注时间：\(Format.duration(metrics.focusTime))；深度工作（单段 25 分钟以上）：\(Format.duration(metrics.deepWorkTime))；最长专注：\(Format.duration(metrics.longestFocusStretch))
            会议：\(Format.duration(metrics.meetingTime))；分心：\(Format.duration(metrics.distractingTime))
            上下文切换：\(metrics.contextSwitches) 次（每小时 \(String(format: "%.0f", metrics.switchesPerHour)) 次）
            专注分：\(metrics.score.map { "\($0.value)/100（\($0.label)）" } ?? "无")
            主要分类：\(categories.joined(separator: "、"))
            主要应用：\(apps.joined(separator: "、"))
            主要网站：\(sites.joined(separator: "、"))
            最忙的时段：\(busiest.joined(separator: "、"))
            """
    }
}

// MARK: - Breakdowns

struct CategoryBreakdown: View {
    @Environment(AppModel.self) private var model
    let metrics: DayMetrics

    @State private var showAll = false

    var body: some View {
        let sorted = metrics.byCategory.sorted { $0.value > $1.value }
        // The top few, plus anything with a real share of the day; the rest is one row.
        let main = sorted.enumerated().filter { $0.offset < 4 || $0.element.value >= metrics.activeTime * 0.05 }.map(\.element)
        let rest = sorted.dropFirst(main.count)
        let restTime = rest.reduce(0) { $0 + $1.value }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(showAll ? sorted : main, id: \.key) { key, value in
                let category = model.classifier.category(key)
                BarRow(label: category.name, value: value, total: metrics.activeTime, color: category.color,
                       detail: Format.percent(value / max(metrics.activeTime, 1)))
            }
            if !rest.isEmpty {
                Button {
                    withAnimation(.snappy) { showAll.toggle() }
                } label: {
                    HStack {
                        Text(showAll ? "收起" : "还有 \(rest.count) 项 · \(rest.map { model.classifier.category($0.key).name }.prefix(3).joined(separator: "、"))\(rest.count > 3 ? "…" : "")")
                            .lineLimit(1)
                        Spacer()
                        if !showAll {
                            Text(Format.duration(restTime)).monospacedDigit()
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Time per app, with each browser's sites nested under it so nothing is counted twice.
private struct AppBreakdown: View {
    @Environment(AppModel.self) private var model
    let samples: [SegmentSample]
    let total: TimeInterval
    @State private var expanded: Set<String> = []

    private struct Usage {
        var bundleID: String
        var name: String
        var time: TimeInterval = 0
        var sites: [String: TimeInterval] = [:]
        var categories: [String: TimeInterval] = [:]
        /// Where most of the app's time went, to color its bar.
        var mainCategory: String? { categories.max { $0.value < $1.value }?.key }
    }

    var body: some View {
        let apps = usage()
        VStack(alignment: .leading, spacing: 10) {
            ForEach(apps.prefix(10), id: \.bundleID) { app in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(nsImage: AppIcons.icon(for: app.bundleID)).resizable().frame(width: 18, height: 18)
                        BarRow(label: app.name, value: app.time, total: total,
                               color: app.mainCategory.map { model.classifier.category($0).color } ?? .accentColor,
                               detail: Format.percent(app.time / max(total, 1)))
                        // Every row reserves the same slot so the bars line up.
                        ZStack {
                            Color.clear.frame(height: 1)
                            if !app.sites.isEmpty {
                                Button {
                                    if expanded.contains(app.bundleID) { expanded.remove(app.bundleID) } else { expanded.insert(app.bundleID) }
                                } label: {
                                    Image(systemName: expanded.contains(app.bundleID) ? "chevron.up" : "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .help("\(app.sites.count) 个网站")
                            }
                        }
                        .frame(width: 16)
                    }
                    if expanded.contains(app.bundleID) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(app.sites.sorted { $0.value > $1.value }.prefix(10), id: \.key) { site, time in
                                HStack {
                                    Image(systemName: "globe").foregroundStyle(.tertiary)
                                    Text(site)
                                    Spacer()
                                    Text(Format.duration(time)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.leading, 26)
                    }
                }
            }
        }
    }

    private func usage() -> [Usage] {
        var apps: [String: Usage] = [:]
        for sample in samples {
            var app = apps[sample.bundleID] ?? Usage(bundleID: sample.bundleID, name: sample.appName.isEmpty ? sample.bundleID : sample.appName)
            app.time += sample.duration
            app.categories[sample.categoryKey, default: 0] += sample.duration
            if let domain = sample.domain { app.sites[domain, default: 0] += sample.duration }
            apps[sample.bundleID] = app
        }
        return apps.values.sorted { $0.time > $1.time }
    }
}

/// "↑ 18m" in green when things went the right way, orange when not.
struct ChangeLabel: View {
    enum Unit { case duration, points }

    let change: Change
    var unit: Unit = .duration
    var higherIsBetter = true
    /// Shown after the value, e.g. "与上周相比".
    var suffix: String? = nil
    var help: String? = nil

    var body: some View {
        let context = suffix ?? help ?? ""
        Group {
            if isFlat {
                Text("≈ 持平" + (suffix.map { " \($0)" } ?? "")).foregroundStyle(.secondary)
            } else {
                let isUp = change.difference > 0
                HStack(spacing: 2) {
                    Image(systemName: isUp ? "arrow.up" : "arrow.down").imageScale(.small)
                    Text(amount).monospacedDigit()
                    if let suffix { Text(suffix).foregroundStyle(.secondary).padding(.leading, 2) }
                }
                .foregroundStyle(isUp == higherIsBetter ? Color.green : Color.orange)
            }
        }
        .font(.caption)
        .help(context)
    }

    private var isFlat: Bool {
        switch unit {
        case .duration: change.isFlat() || abs(change.difference) < 60
        case .points: abs(change.difference) < 2
        }
    }

    private var amount: String {
        switch unit {
        case .duration: Format.duration(abs(change.difference))
        case .points: "\(Int(abs(change.difference).rounded()))"
        }
    }
}

struct BarRow: View {
    let label: String
    let value: TimeInterval
    let total: TimeInterval
    let color: Color
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                if let detail {
                    Text(detail).monospacedDigit().foregroundStyle(.tertiary)
                }
                Text(Format.duration(value)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .font(.callout)
            GeometryReader { proxy in
                Capsule().fill(color.gradient)
                    .frame(width: max(3, proxy.size.width * value / max(total, 1)))
            }
            .frame(height: 5)
        }
    }
}
