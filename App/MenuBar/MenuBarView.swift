import WeftKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TodayCard(day: Calendar.current.startOfDay(for: .now))
                .id(Calendar.current.startOfDay(for: .now))
            CurrentActivityRow(openSettings: showSettings)
            SessionSection()
            if let summary = model.sessions.lastSummary, summary.kind != .breakTime {
                SessionSummaryCard(summary: summary)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 330)
    }

    private var footer: some View {
        @Bindable var preferences = model.preferences
        return HStack(spacing: 12) {
            // A status, not a toggle: green while tracking, orange while paused.
            Button {
                preferences.trackingPaused.toggle()
            } label: {
                HStack(spacing: 6) {
                    if preferences.trackingPaused {
                        Image(systemName: "pause.fill").font(.caption2).foregroundStyle(.orange)
                        Text("已暂停").foregroundStyle(.orange)
                    } else {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("追踪").foregroundStyle(.primary)
                    }
                }
                .frame(minWidth: 84, alignment: .leading)
            }
            .help(preferences.trackingPaused ? "点击继续追踪" : "点击暂停追踪")

            Spacer()
            Button("打开面板") {
                model.showDay()
                openWindow(id: MainView.windowID)
                NSApp.activate()
            }
            Button(action: showSettings) { Image(systemName: "gearshape") }
                .help("设置")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("退出 Weft")
        }
        .buttonStyle(.borderless)
    }

    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}

// MARK: - Today

private struct TodayCard: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]
    private let day: Date

    init(day: Date) {
        self.day = day
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > day }, sort: \.start)
    }

    var body: some View {
        let samples = segments.map { segment -> SegmentSample in
            var sample = SegmentSample(segment)
            sample.start = max(sample.start, day)
            return sample
        }
        let metrics = DayMetrics.compute(samples, categories: model.classifier.categoryLookup)
        let target = model.preferences.workHoursTarget * 3600

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.wide)))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Format.duration(metrics.activeTime))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("目标 \(Format.duration(target)) · \(Format.percent(metrics.activeTime / max(target, 1)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ScoreRing(score: metrics.score, activeTime: metrics.activeTime)
            }
            GoalBar(metrics: metrics, target: target)
            HStack(spacing: 14) {
                LegendItem(color: GoalBar.focusColor, title: "专注", value: metrics.focusTime)
                LegendItem(color: GoalBar.meetingColor, title: "会议", value: metrics.meetingTime)
                LegendItem(color: GoalBar.distractedColor, title: "分心", value: metrics.distractingTime)
            }
        }
    }
}

/// A Focus Score gauge. Low scores are shown in a neutral color rather than red, and nothing
/// is judged until there's enough data.
struct ScoreRing: View {
    let score: FocusScore?
    var activeTime: TimeInterval = .infinity
    var size: CGFloat = 56

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: size * 0.11)
                if let score {
                    Circle()
                        .trim(from: 0, to: CGFloat(score.value) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(score.map { "\($0.value)" } ?? "–")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: size, height: size)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .help("专注分")
    }

    /// A couple of hours in, a score still swings a lot; don't grade it yet.
    private var isEarly: Bool { activeTime < 2 * 3600 }

    private var caption: String {
        guard let score else { return "正在收集数据" }
        return isEarly ? "早期估计" : score.label
    }

    private var color: Color {
        guard let value = score?.value, !isEarly else { return .secondary }
        return value >= 80 ? .green : value >= 50 ? .orange : .indigo
    }
}

/// One bar for the day: its full width is the work-hours target and the filled part is
/// tracked time, split into focus, meetings, other and distracted.
struct GoalBar: View {
    let metrics: DayMetrics
    let target: TimeInterval

    static let focusColor = Color.blue
    static let meetingColor = Color.teal
    static let otherColor = Color.gray
    static let distractedColor = Color.red

    var body: some View {
        let scale = max(target, metrics.activeTime, 1)
        let other = max(0, metrics.activeTime - metrics.focusTime - metrics.meetingTime - metrics.distractingTime)
        let parts: [(String, TimeInterval, Color)] = [
            ("专注", metrics.focusTime, Self.focusColor),
            ("会议", metrics.meetingTime, Self.meetingColor),
            ("其他", other, Self.otherColor),
            ("分心", metrics.distractingTime, Self.distractedColor),
        ].filter { $0.1 > 0 }
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(parts, id: \.0) { name, value, color in
                    Rectangle()
                        .fill(color.gradient)
                        .frame(width: max(2, proxy.size.width * value / scale))
                        .help("\(name)：\(Format.duration(value))")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Capsule().fill(.quaternary))
        .clipShape(Capsule())
        .help("距离 \(Format.duration(target)) 的目标已记录的时间")
    }
}

private struct LegendItem: View {
    let color: Color
    let title: String
    let value: TimeInterval

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
            Text(Format.duration(value)).monospacedDigit()
        }
        .font(.caption)
    }
}

// MARK: - Now

private struct CurrentActivityRow: View {
    @Environment(AppModel.self) private var model
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let context = model.tracker.current, let category = model.tracker.currentCategory {
                    Image(nsImage: AppIcons.icon(for: context.bundleID))
                        .resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.domain ?? context.appName).font(.callout.weight(.medium)).lineLimit(1)
                        if let title = context.title {
                            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    CategoryChip(category: category)
                } else {
                    Image(systemName: model.preferences.trackingPaused ? "pause.circle" : "moon.zzz")
                        .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                    Text(model.preferences.trackingPaused ? "追踪已暂停" : "离开")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            // Same height whether tracking, away or paused, so the panel doesn't jump.
            .frame(height: 34)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            if !model.accessibilityGranted {
                Button {
                    SystemProbe.requestAccessibility()
                    openSettings()
                } label: {
                    Label("授权辅助功能，以便记录窗口标题", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
    }
}

struct CategoryChip: View {
    let category: CategoryDefinition

    var body: some View {
        Text(category.name)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(category.color.opacity(0.2)))
            .foregroundStyle(category.color)
    }
}

// MARK: - Sessions

private struct SessionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.sessions.active {
            ActiveSessionRow(session: session)
        } else {
            HStack(spacing: 8) {
                ForEach(SessionKind.allCases) { kind in
                    SessionButton(kind: kind)
                }
            }
        }
    }
}

/// A tile that starts a session with the default duration. The duration underneath is a
/// menu for picking another one.
private struct SessionButton: View {
    @Environment(AppModel.self) private var model
    let kind: SessionKind
    @State private var isHovering = false
    @State private var isHoveringDuration = false

    var body: some View {
        let minutes = model.preferences.defaultMinutes(for: kind)
        VStack(spacing: 2) {
            Button {
                model.startSession(kind)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: kind.symbol).font(.title3).frame(height: 22)
                    Text(kind.title).font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("开始一个 \(Format.minutesLabel(minutes)) 的\(kind.title)时段")

            Menu {
                Section("开始一个\(kind.title)时段") {
                    ForEach(SessionEngine.presetMinutes, id: \.self) { preset in
                        Button(Format.minutesLabel(preset)) { model.startSession(kind, minutes: preset) }
                    }
                }
            } label: {
                Text(Format.duration(TimeInterval(minutes * 60)))
                    .font(.caption)
                    .foregroundStyle(isHoveringDuration ? .primary : .secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            // Lights up on hover to show it can be clicked for other durations.
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(.primary.opacity(isHoveringDuration ? 0.12 : 0)))
            .onHover { isHoveringDuration = $0 }
            .padding(.bottom, 7)
            .help("选择其他时长")
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(isHovering ? 0.9 : 0.5)))
        .onHover { isHovering = $0 }
    }
}

private struct ActiveSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: ActiveSession

    var body: some View {
        let remaining = session.remaining(at: model.sessions.now)
        let progress = 1 - remaining / max(session.plannedDuration, 1)
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: session.kind.symbol).font(.callout)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.kind.title)时段").font(.caption).foregroundStyle(.secondary)
                Text(Format.countdown(remaining))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            Button("+5 分钟") { model.sessions.extend(minutes: 5) }
            Button("结束") { model.sessions.stop() }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

extension SessionKind {
    var symbol: String {
        switch self {
        case .focus: "scope"
        case .meeting: "person.2"
        case .breakTime: "cup.and.saucer"
        }
    }
}

struct SessionSummaryCard: View {
    @Environment(AppModel.self) private var model
    let summary: SessionSummary
    @State private var rating: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(summary.kind.title)时段 · \(Format.duration(summary.end.timeIntervalSince(summary.start)))")
                    .font(.callout.weight(.medium))
                Spacer()
                Button { model.sessions.dismissSummary() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 16) {
                ScoreRing(score: summary.score, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("专注占 \(summary.focusPercent.map(Format.percent) ?? "–")")
                    Text(summary.distractions == 0 ? "没有分心" : "\(summary.distractions) 次分心")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Text("你觉得这次专注度如何？").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(1...10, id: \.self) { value in
                    Button("\(value)") {
                        rating = value
                        model.sessions.rate(value, summary: summary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(rating == value ? .accentColor : nil)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}
