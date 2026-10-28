import WeftKit
import SwiftData
import SwiftUI

struct ActivityList: View {
    @Environment(AppModel.self) private var model
    let segments: [ActivitySegment]
    @State private var showAll = false
    @State private var search = ""
    @State private var category: String?

    var body: some View {
        let all = Array(ActivityBlocks.build(segments).filter { $0.duration >= 10 }.reversed())
        let groups = all.filter(matches)
        let visible = showAll ? groups : Array(groups.prefix(40))
        let categories = Set(all.map(\.first.categoryKey)).map(model.classifier.category).sorted { $0.name < $1.name }
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("按应用、网站或标题筛选", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Picker("分类", selection: $category) {
                    Text("全部分类").tag(String?.none)
                    Divider()
                    ForEach(categories) { Text($0.name).tag(Optional($0.key)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                if groups.count != all.count {
                    Text("\(groups.count) / \(all.count) 条").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)
            if groups.isEmpty {
                Text("没有匹配的记录。").foregroundStyle(.secondary).padding(.vertical, 12)
            }
            ForEach(visible) { group in
                ActivityRow(group: group)
                Divider()
            }
            if groups.count > visible.count {
                Button("显示全部 \(groups.count) 条") { showAll = true }
                    .buttonStyle(.link)
                    .padding(.top, 8)
            }
        }
    }

    private func matches(_ group: ActivityBlock) -> Bool {
        if let category, group.first.categoryKey != category { return false }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return group.first.appName.localizedCaseInsensitiveContains(query)
            || (group.first.domain?.localizedCaseInsensitiveContains(query) ?? false)
            || group.titles.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

private struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let group: ActivityBlock

    var body: some View {
        let category = model.classifier.category(group.first.categoryKey)
        HStack(alignment: .top, spacing: 10) {
            Text(timeRange)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Image(nsImage: AppIcons.icon(for: group.first.bundleID))
                .resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.first.domain ?? group.first.appName).font(.callout.weight(.medium))
                let titles = group.titles
                if let title = titles.first {
                    Text(titles.count > 1 ? "\(title) (+\(titles.count - 1))" : title)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(titles.prefix(10).joined(separator: "\n"))
                }
                if !group.interruptions.isEmpty {
                    let names = group.interruptionNames
                    Label("\(group.interruptions.count) 次短暂切换 · \(names.prefix(3).joined(separator: "、"))\(names.count > 3 ? "…" : "")",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        .help("已并入这条记录的短暂访问：\n" + names.joined(separator: "\n"))
                }
            }
            Spacer()
            Text(Format.duration(group.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            CategoryMenu(group: group, category: category)
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    /// "15:36–15:37", or just "16:30" when it starts and ends in the same minute.
    private var timeRange: String {
        let start = group.start.formatted(date: .omitted, time: .shortened)
        let end = group.end.formatted(date: .omitted, time: .shortened)
        return start == end ? start : "\(start)–\(end)"
    }
}

/// Lets the user fix a classification, either just here or as a rule for the app/site.
struct CategoryMenu: View {
    @Environment(AppModel.self) private var model
    let group: ActivityBlock
    let category: CategoryDefinition

    var body: some View {
        let target = group.first.domain ?? group.first.appName
        // A borderless menu only renders the label's text, so the dot sits outside it.
        HStack(spacing: 4) {
            Circle().fill(category.color).frame(width: 8, height: 8)
            Menu {
                Menu("始终如此：\(target)") {
                    categoryButtons { key in
                        if let domain = group.first.domain {
                            model.classifier.addRule(field: .domain, pattern: domain, categoryKey: key)
                        } else {
                            model.classifier.addRule(field: .bundleID, pattern: group.first.bundleID, categoryKey: key)
                        }
                    }
                }
                Menu("只改这一条") {
                    categoryButtons { key in
                        for segment in group.segments { model.classifier.setManualCategory(key, for: segment) }
                    }
                }
            } label: {
                Text(category.name)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if group.first.classificationSource == .pending {
                Image(systemName: "sparkles").foregroundStyle(.secondary).help("等待设备端分类")
            }
        }
    }

    @ViewBuilder
    private func categoryButtons(_ action: @escaping (String) -> Void) -> some View {
        ForEach(model.classifier.categories.filter { $0.key != CategoryDefinition.uncategorizedKey }) { category in
            Button(category.name) { action(category.key) }
        }
    }
}
