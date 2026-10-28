import WeftKit
import SwiftData
import SwiftUI

/// Apps and sites no rule knew: still waiting for the model, or classified by it and not yet
/// confirmed. Confirming or changing one creates a rule, which takes it off this list.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Query private var segments: [ActivitySegment]

    init() {
        let since = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let pending = ClassificationSource.pending.rawValue
        let ai = ClassificationSource.ai.rawValue
        _segments = Query(filter: #Predicate<ActivitySegment> {
            $0.end > since && ($0.classificationSourceRaw == pending || $0.classificationSourceRaw == ai)
        })
    }

    private struct Item: Identifiable {
        var key: String
        var sample: ActivitySegment
        var duration: TimeInterval
        var categoryKey: String
        var source: ClassificationSource
        var confidence: AIConfidence?
        var id: String { key }
    }

    var body: some View {
        let items = items()
        VStack(spacing: 0) {
            statusBar
            Divider()
            if items.isEmpty {
                ContentUnavailableView("没有待确认的内容", systemImage: "checkmark.circle",
                                       description: Text("最近 30 天的应用和网站都已有规则覆盖。"))
                    .frame(maxHeight: .infinity)
            } else {
                Table(items) {
                    TableColumn("应用 / 网站") { item in
                        HStack {
                            Image(nsImage: AppIcons.icon(for: item.sample.bundleID)).resizable().frame(width: 16, height: 16)
                            VStack(alignment: .leading) {
                                Text(item.sample.domain ?? item.sample.appName)
                                if item.sample.domain != nil {
                                    Text(item.sample.appName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    TableColumn("时长（30 天）") { item in
                        Text(Format.duration(item.duration)).monospacedDigit()
                    }
                    .width(110)
                    TableColumn("状态") { item in
                        switch item.source {
                        case .pending: Label("等待中", systemImage: "hourglass").foregroundStyle(.secondary)
                        default: Text("AI · \(item.confidence?.rawValue ?? "?") 置信度").foregroundStyle(.secondary)
                        }
                    }
                    .width(160)
                    TableColumn("分类") { item in
                        Picker("", selection: Binding(
                            get: { item.categoryKey },
                            set: { assign(item, to: $0) }
                        )) {
                            ForEach(model.classifier.categories) { category in
                                Text(category.name).tag(category.key)
                            }
                        }
                        .labelsHidden()
                    }
                    .width(180)
                    TableColumn("") { item in
                        Button {
                            assign(item, to: item.categoryKey)
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(item.source == .pending)
                        .help("确认无误——这个应用/网站保持「\(model.classifier.category(item.categoryKey).name)」")
                    }
                    .width(30)
                }
            }
        }
        .navigationTitle("待确认")
        .toolbar {
            let confident = items.filter { $0.source == .ai && $0.confidence == .high }
            Button {
                for item in confident { assign(item, to: item.categoryKey) }
            } label: {
                Label("确认 \(confident.count) 个高置信度项", systemImage: "checkmark.circle")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(confident.isEmpty)
            .help("对模型有把握的应用和网站，保留它给出的分类")
        }
    }

    private var statusBar: some View {
        HStack {
            switch model.classifier.aiAvailability {
            case .available:
                Image(systemName: "sparkles")
                Text(model.classifier.queuedCount > 0
                     ? "正在设备端分类 \(model.classifier.queuedCount) 个应用/网站…"
                     : "设备端分类已开启。")
                if model.classifier.queuedCount > 0 { ProgressView().controlSize(.small) }
            case .unavailable(let reason):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(reason)
                Button("打开设置") { SystemSettings.openAppleIntelligence() }
            }
            Spacer()
            Button("重试") { model.classifier.retryPending() }
                .help("对仍在等待的所有项目重新请求模型")
        }
        .font(.callout)
        .padding(12)
    }

    private func items() -> [Item] {
        var byKey: [String: Item] = [:]
        for segment in segments {
            let key = segment.classificationKey
            if var item = byKey[key] {
                item.duration += segment.duration
                byKey[key] = item
            } else {
                byKey[key] = Item(key: key, sample: segment, duration: segment.duration, categoryKey: segment.categoryKey,
                                  source: segment.classificationSource, confidence: model.classifier.confidence(forKey: key))
            }
        }
        // Waiting first, then least confident, then most time spent.
        func rank(_ item: Item) -> Int {
            switch (item.source, item.confidence) {
            case (.pending, _): 0
            case (_, .low?), (_, nil): 1
            case (_, .medium?): 2
            case (_, .high?): 3
            }
        }
        return byKey.values.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.duration > b.duration
        }
    }

    private func assign(_ item: Item, to categoryKey: String) {
        if let domain = item.sample.domain {
            model.classifier.addRule(field: .domain, pattern: domain, categoryKey: categoryKey)
        } else {
            model.classifier.addRule(field: .bundleID, pattern: item.sample.bundleID, categoryKey: categoryKey)
        }
    }
}
