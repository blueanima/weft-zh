import Charts
import WeftKit
import SwiftData
import SwiftUI

struct ReportsView: View {
    /// First day of the calendar week shown.
    @State private var weekStart = ReportsView.week(containing: .now).start

    var body: some View {
        let week = ReportsView.week(containing: weekStart)
        let isCurrent = week.contains(.now)
        WeekReport(start: week.start)
            .id(week.start)
            .navigationTitle("报告")
            .navigationSubtitle(rangeLabel(week))
            .toolbar {
                ToolbarItemGroup {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .help("上一周")
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("本周") { weekStart = ReportsView.week(containing: .now).start }
                        .disabled(isCurrent)
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .help("下一周")
                        .disabled(isCurrent)
                        .keyboardShortcut(.rightArrow, modifiers: .command)
                }
            }
    }

    static func week(containing date: Date) -> DateInterval {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: Calendar.current.startOfDay(for: date), duration: 7 * 86400)
    }

    private func rangeLabel(_ week: DateInterval) -> String {
        let last = week.end.addingTimeInterval(-1)
        return "\(week.start.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day().year()))"
    }

    private func shift(_ weeks: Int) {
        weekStart = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: weekStart) ?? weekStart
    }
}

private struct DayStat: Identifiable {
    var day: Date
    var metrics: DayMetrics
    var id: Date { day }
}

private struct DayCategory: Identifiable {
    var day: Date
    var category: String
    var hours: Double
    var id: String { "\(day.timeIntervalSince1970)-\(category)" }
}

private struct WeekReport: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]
    private let days: [Date]

    @State private var hoveredDay: Date?

    /// Categories beyond this many share one grey "其他" in the chart.
    private let chartCategories = 5
    private static let otherKey = "__other"

    /// Includes the week before, to compare against.
    init(start: Date) {
        let calendar = Calendar.current
        days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let from = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > from && $0.start < end }, sort: \.start)
    }

    var body: some View {
        let stats = dailyStats(days)
        let summary = PeriodSummary(stats.map(\.metrics))
        let last = PeriodSummary(dailyStats(days.compactMap { Calendar.current.date(byAdding: .day, value: -7, to: $0) }).map(\.metrics))
        let total = summary.total
        let average = summary.averageScore
        // Matches the score ring: short days aren't graded yet.
        let isEarly = stats.allSatisfy { $0.metrics.score == nil || $0.metrics.activeTime < 2 * 3600 }
        // Only compare with a week that was tracked at all.
        let change = { (value: KeyPath<DayMetrics, TimeInterval>) -> Change? in
            last.activeDays > 0 ? Change(total[keyPath: value], baseline: last.total[keyPath: value]) : nil
        }

        ScrollView {
            if total.activeTime == 0 {
                ContentUnavailableView("本周没有活动", systemImage: "chart.bar",
                                       description: Text("这段时间内没有记录到任何活动。"))
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        summaryTile("记录时长", total.activeTime, change: change(\.activeTime),
                                    "\(summary.activeDays) 天里平均每天 \(Format.duration(total.activeTime / Double(max(summary.activeDays, 1))))")
                        summaryTile("专注", total.focusTime, change: change(\.focusTime), "深度工作 \(Format.duration(total.deepWorkTime))")
                        summaryTile("会议", total.meetingTime, change: change(\.meetingTime), higherIsBetter: false,
                                    share(total.meetingTime, of: total.activeTime))
                        summaryTile("分心", total.distractingTime, change: change(\.distractingTime), higherIsBetter: false,
                                    share(total.distractingTime, of: total.activeTime))
                        tile("平均专注分", average.map(String.init) ?? "–", isEmpty: average == nil,
                             change: average.flatMap { now in last.averageScore.map { ChangeLabel(change: Change(Double(now), baseline: Double($0)), unit: .points, help: "与上周相比") } },
                             average.map { isEarly ? "早期估计" : FocusScore.label(for: $0) } ?? "暂无评分")
                    }
                    Card("各分类用时") { categoryChart(stats, total: total) }
                    Card("专注分") { scoreChart(stats) }
                    Card("本周分类") { CategoryBreakdown(metrics: total) }
                }
                .padding(20)
            }
        }
    }

    private func dailyStats(_ days: [Date]) -> [DayStat] {
        let calendar = Calendar.current
        let intervals = days.map { DateInterval(start: $0, end: calendar.date(byAdding: .day, value: 1, to: $0) ?? $0) }
        let metrics = DayMetrics.daily(segments.map(SegmentSample.init), days: intervals,
                                       categories: model.classifier.categoryLookup)
        return zip(days, metrics).map { DayStat(day: $0, metrics: $1) }
    }

    private func categoryChart(_ stats: [DayStat], total: DayMetrics) -> some View {
        // Biggest first, so the bars stack the same way every day and the legend reads in order.
        let ranked = total.byCategory.sorted { $0.value > $1.value }.map(\.key)
        let shown = Array(ranked.prefix(ranked.count > chartCategories + 1 ? chartCategories : ranked.count))
        let keys = shown + (ranked.count > shown.count ? [Self.otherKey] : [])
        let rows = stats.flatMap { stat in
            var hours: [String: Double] = [:]
            for (key, value) in stat.metrics.byCategory {
                hours[shown.contains(key) ? key : Self.otherKey, default: 0] += value / 3600
            }
            return keys.compactMap { key in hours[key].map { DayCategory(day: stat.day, category: key, hours: $0) } }
        }
        let target = model.preferences.workHoursTarget
        return Chart {
            ForEach(rows) { row in
                BarMark(x: .value("日期", row.day, unit: .day), y: .value("小时", row.hours))
                    .foregroundStyle(by: .value("分类", name(row.category)))
            }
            if let hoveredDay, let stat = stats.first(where: { $0.day == hoveredDay }) {
                RectangleMark(x: .value("日期", hoveredDay, unit: .day))
                    .foregroundStyle(Color.primary.opacity(0.06))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(Format.duration(stat.metrics.activeTime)).fontWeight(.semibold).monospacedDigit()
                            Text(stat.metrics.activeTime > 0 ? "点击查看" : "没有活动").foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                    }
            }
            if target > 0 {
                RuleMark(y: .value("目标", target))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("目标 \(Format.duration(target * 3600))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartForegroundStyleScale(domain: keys.map(name), range: keys.map(color))
        .chartXScale(domain: weekDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true) }
        }
        .chartYAxisLabel("hours")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hoveredDay = day(at: location, proxy, geometry)
                        case .ended: hoveredDay = nil
                        }
                    }
                    .onTapGesture { location in
                        if let day = day(at: location, proxy, geometry) { model.showDay(day) }
                    }
            }
        }
        .frame(height: 240)
    }

    private func day(at location: CGPoint, _ proxy: ChartProxy, _ geometry: GeometryProxy) -> Date? {
        guard let frame = proxy.plotFrame.map({ geometry[$0] }),
              let date: Date = proxy.value(atX: location.x - frame.origin.x) else { return nil }
        let day = Calendar.current.startOfDay(for: date)
        return days.contains(day) ? day : nil
    }

    private func name(_ key: String) -> String {
        key == Self.otherKey ? "其他" : model.classifier.category(key).name
    }

    private func color(_ key: String) -> Color {
        key == Self.otherKey ? .gray.opacity(0.5) : model.classifier.category(key).color
    }

    private func scoreChart(_ stats: [DayStat]) -> some View {
        // Only consecutive days are joined, so a gap doesn't read as a trend.
        var run = 0
        var points: [(stat: DayStat, run: Int)] = []
        for stat in stats {
            if stat.metrics.score == nil { run += 1 } else { points.append((stat, run)) }
        }
        return Chart(points, id: \.stat.id) { point in
            let value = point.stat.metrics.score?.value ?? 0
            LineMark(x: .value("日期", point.stat.day, unit: .day), y: .value("分数", value))
                .foregroundStyle(by: .value("段", point.run))
            PointMark(x: .value("日期", point.stat.day, unit: .day), y: .value("分数", value))
                .foregroundStyle(by: .value("段", point.run))
                .annotation(position: .top) { Text("\(value)").font(.caption2) }
        }
        .chartForegroundStyleScale(range: [Color.accentColor])
        .chartLegend(.hidden)
        .chartXScale(domain: weekDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true) }
        }
        .chartYScale(domain: 0...100)
        .frame(height: 140)
    }

    /// Always show all seven days, even when only one has data.
    private var weekDomain: ClosedRange<Date> {
        let start = days.first ?? .now
        let end = Calendar.current.date(byAdding: .day, value: 1, to: days.last ?? start) ?? start
        return start...end
    }

    private func share(_ value: TimeInterval, of total: TimeInterval) -> String {
        value == 0 ? "无" : "占记录时长 \(Format.percent(value / max(total, 1)))"
    }

    private func summaryTile(_ title: String, _ value: TimeInterval, change: Change?, higherIsBetter: Bool = true,
                             _ detail: String) -> some View {
        tile(title, Format.duration(value), isEmpty: value == 0,
             change: change.map { ChangeLabel(change: $0, higherIsBetter: higherIsBetter, help: "与上周相比") }, detail)
    }

    private func tile(_ title: String, _ value: String, isEmpty: Bool, change: ChangeLabel?, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(isEmpty ? .tertiary : .primary)
                change
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}
