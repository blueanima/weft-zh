import WeftKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The standard macOS settings window (⌘,), one tab per area.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") { GeneralSettings() }
            Tab("AI", systemImage: "sparkles") { AISettingsPane() }
            Tab("追踪", systemImage: "record.circle") { TrackingSettings() }
            Tab("时段", systemImage: "timer") { SessionSettings() }
            Tab("拦截", systemImage: "hand.raised") { BlockerSettings() }
            Tab("数据", systemImage: "externaldrive") { DataSettings() }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
        .onAppear { model.refreshPermissions() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("登录时启动 Weft", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
                Toggle("暂停追踪", isOn: $prefs.trackingPaused)
            }
            Section("工作时长") {
                Picker("每日目标", selection: $prefs.workHoursTarget) {
                    ForEach([4.0, 5, 6, 7, 7.5, 8, 8.5, 9, 10, 12], id: \.self) { hours in
                        Text(Format.duration(hours * 3600)).tag(hours)
                    }
                }
                Toggle("达成目标时提醒，超出过多时也提醒", isOn: $prefs.workHoursNotifications)
            }
            Section("权限") {
                PermissionRow(
                    title: "辅助功能",
                    detail: "用于读取窗口标题。",
                    granted: model.accessibilityGranted,
                    action: { SystemProbe.requestAccessibility(); SystemSettings.openAccessibility() }
                )
                LabeledContent {
                    Button("打开设置") { SystemSettings.openAutomation() }
                } label: {
                    Text("浏览器")
                    Text("每个浏览器会询问一次是否允许 Weft 读取当前标签页的网址。")
                }
                LabeledContent {
                    switch model.classifier.aiAvailability {
                    case .available: Label("可用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable where model.preferences.aiProvider == .apple:
                        Button("打开设置") { SystemSettings.openAppleIntelligence() }
                    case .unavailable: Text("未启用").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("AI 引擎")
                    switch model.classifier.aiAvailability {
                    case .available: Text("当前用 \(model.preferences.aiProvider.title) 分类和写摘要，可在「AI」页签切换。")
                    case .unavailable(let reason): Text(reason)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("授权", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - AI

private struct AISettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""
    @State private var status: String?
    @State private var models: [String] = []
    @State private var busy = false

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("引擎", selection: $prefs.aiProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(prefs.aiProvider.detail).font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("分类与摘要由谁来做")
            } footer: {
                Text("选 DeepSeek 时，应用名、窗口标题和网址会发送到 api.deepseek.com；选 Apple 智能则全部在本机完成。内置规则和已有分类缓存不受影响。没有可用模型时，认不出的应用和网站会先按 App Store 分类和域名推测，在「待确认」里标为「推测」。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if prefs.aiProvider == .deepSeek {
                Section {
                    SecureField("API Key", text: $keyDraft, prompt: Text("sk-…"))
                        .onSubmit(saveKey)
                    HStack {
                        Button("保存 Key", action: saveKey)
                        Text(prefs.deepSeekAPIKey.isEmpty ? "尚未保存" : "已存入钥匙串")
                            .font(.caption)
                            .foregroundStyle(prefs.deepSeekAPIKey.isEmpty ? .orange : .secondary)
                        Spacer()
                        Button("清除") {
                            keyDraft = ""
                            saveKey()
                        }
                        .disabled(prefs.deepSeekAPIKey.isEmpty)
                    }
                    TextField("模型", text: $prefs.deepSeekModel, prompt: Text(DeepSeekConfig.defaultModel))
                    TextField("接口地址", text: $prefs.deepSeekBaseURL, prompt: Text(DeepSeekConfig.defaultBaseURL))
                    if models.count > 1 {
                        Picker("这个 Key 可用的模型", selection: $prefs.deepSeekModel) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Toggle("思考模式", isOn: $prefs.deepSeekThinking)
                } header: {
                    Text("DeepSeek")
                } footer: {
                    Text("分类和一句话摘要都属于短任务，关掉思考模式更快也更省。改成自己的网关地址也可以，例如 https://your-proxy/v1。")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section {
                    HStack(spacing: 12) {
                        Button("测试连接") { Task { await ping() } }
                            .disabled(busy)
                        Button("获取模型列表") { Task { await fetchModels() } }
                            .disabled(busy)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    if let status {
                        Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }

            if prefs.aiProvider == .apple {
                Section("Apple 智能") {
                    LabeledContent {
                        switch model.classifier.aiAvailability {
                        case .available:
                            Label("可用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .unavailable:
                            Button("打开设置") { SystemSettings.openAppleIntelligence() }
                        }
                    } label: {
                        Text("状态")
                        switch model.classifier.aiAvailability {
                        case .available: Text("陌生的应用和网站会在设备端完成分类。")
                        case .unavailable(let reason): Text(reason)
                        }
                    }
                }
            }

            Section("当前状态") {
                LabeledContent("可用性") {
                    switch model.classifier.aiAvailability {
                    case .available:
                        Label("可用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable(let reason):
                        Text(reason).foregroundStyle(.secondary)
                    }
                }
                if model.classifier.queuedCount > 0 {
                    LabeledContent("排队分类", value: "\(model.classifier.queuedCount) 个应用/网站")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { keyDraft = model.preferences.deepSeekAPIKey }
        .onChange(of: prefs.aiProvider) { model.applyAISettings() }
        .onChange(of: prefs.aiSettings) { model.updateAIModel() }
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.preferences.deepSeekAPIKey = trimmed
        model.applyAISettings()
        status = trimmed.isEmpty ? "已清除 API Key。" : "API Key 已保存到钥匙串。"
    }

    private func ping() async {
        saveKey()
        guard model.ai.deepSeek.availability() == .available else {
            status = "先填写 API Key。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let reply = try await model.ai.deepSeek.ping()
            status = "连接正常，回复：\(reply.prefix(20))"
            model.classifier.refreshAvailability()
        } catch {
            status = "连接失败：\(error.localizedDescription)"
        }
    }

    private func fetchModels() async {
        saveKey()
        guard model.ai.deepSeek.availability() == .available else {
            status = "先填写 API Key。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            models = try await model.ai.deepSeek.listModels()
            status = models.isEmpty ? "没有拿到模型列表。" : "可用模型：\(models.joined(separator: "、"))"
        } catch {
            status = "获取失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Tracking

private struct TrackingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newDomain = ""

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("离开判定时间", selection: $prefs.idleThresholdMinutes) {
                    ForEach([1, 2, 3, 5, 10, 15, 30], id: \.self) { Text("\($0) 分钟无输入").tag($0) }
                }
            } footer: {
                Text("会议和视频通话永远不会算作离开。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("隐私") {
                Toggle("不记录窗口标题", isOn: $prefs.stripTitles)
                Toggle("只记录网址的域名", isOn: $prefs.urlHostOnly)
            }
            Section {
                ForEach(prefs.excludedBundleIDs, id: \.self) { bundleID in
                    RemovableRow {
                        AppLabel(bundleID: bundleID)
                    } onRemove: {
                        prefs.excludedBundleIDs.removeAll { $0 == bundleID }
                    }
                }
                AppPicker(excluding: Set(prefs.excludedBundleIDs)) { bundleID in
                    prefs.excludedBundleIDs.append(bundleID)
                }
            } header: {
                Text("不追踪这些应用")
            }
            Section("不追踪这些网站") {
                ForEach(prefs.excludedDomains, id: \.self) { domain in
                    RemovableRow {
                        Label(domain, systemImage: "globe")
                    } onRemove: {
                        prefs.excludedDomains.removeAll { $0 == domain }
                    }
                }
                HStack {
                    TextField("域名", text: $newDomain, prompt: Text("bank.example.com"))
                        .labelsHidden()
                        .onSubmit(addDomain)
                    Button("添加", action: addDomain)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addDomain() {
        var value = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let domain = ActivityContext.domain(from: value.contains("://") ? value : "https://\(value)") { value = domain }
        guard !value.isEmpty, !model.preferences.excludedDomains.contains(value) else { return }
        model.preferences.excludedDomains.append(value)
        newDomain = ""
    }
}

/// Adds an app from the ones currently running, or any app chosen in an open panel.
private struct AppPicker: View {
    let excluding: Set<String>
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
                .filter { !excluding.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            Section("正在运行的应用") {
                ForEach(running, id: \.0) { bundleID, name in
                    Button {
                        onPick(bundleID)
                    } label: {
                        Label { Text(name) } icon: { Image(nsImage: AppIcons.icon(for: bundleID)) }
                    }
                }
            }
            Divider()
            Button("选择其他应用…", action: chooseApp)
        } label: {
            Label("添加应用", systemImage: "plus")
        }
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier, !excluding.contains(bundleID) else { return }
        onPick(bundleID)
    }
}

struct AppLabel: View {
    let bundleID: String

    var body: some View {
        Label {
            Text(Self.name(for: bundleID))
        } icon: {
            Image(nsImage: AppIcons.icon(for: bundleID)).resizable().frame(width: 18, height: 18)
        }
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct RemovableRow<Content: View>: View {
    @ViewBuilder let content: Content
    let onRemove: () -> Void

    var body: some View {
        HStack {
            content
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("移除")
        }
    }
}

// MARK: - Sessions

private struct SessionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section("默认时长") {
                durationPicker("专注", $prefs.defaultFocusMinutes, options: [15, 20, 25, 30, 45, 50, 60, 90, 120])
                durationPicker("会议", $prefs.defaultMeetingMinutes, options: [15, 20, 25, 30, 45, 60, 90, 120])
                durationPicker("休息", $prefs.defaultBreakMinutes, options: [1, 3, 5, 10, 15, 20, 30])
                Toggle("休息时全屏提醒", isOn: $prefs.fullScreenBreak)
            }
            Section {
                Toggle("提醒我休息", isOn: $prefs.breakRemindersEnabled)
                durationPicker("连续工作", $prefs.breakReminderMinutes, options: [20, 30, 45, 60, 75, 90, 120])
                    .disabled(!prefs.breakRemindersEnabled)
                durationPicker("推迟", $prefs.snoozeMinutes, options: [5, 10, 15, 20, 30])
                    .disabled(!prefs.breakRemindersEnabled)
            } header: {
                Text("休息提醒")
            } footer: {
                Text("只统计活跃时间；离开键盘后计时会重置。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func durationPicker(_ title: String, _ value: Binding<Int>, options: [Int]) -> some View {
        Picker(title, selection: value) {
            ForEach(Array(Set(options + [value.wrappedValue])).sorted(), id: \.self) { minutes in
                Text(Format.minutesLabel(minutes)).tag(minutes)
            }
        }
    }
}

// MARK: - Blocker

private struct BlockerSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("专注时段拦截分心内容", isOn: $prefs.blockerEnabled)
                Picker("样式", selection: $prefs.blockerStyle) {
                    Text("全屏覆盖").tag(BlockerStyle.overlay)
                    Text("通知").tag(BlockerStyle.notification)
                }
                .pickerStyle(.segmented)
                .disabled(!prefs.blockerEnabled)
                Picker("打断时机", selection: $prefs.refocusThresholdSeconds) {
                    ForEach(Array(Set([0, 5, 10, 15, 30, 60, prefs.refocusThresholdSeconds])).sorted(), id: \.self) { seconds in
                        Text(seconds == 0 ? "立即" : "\(seconds) 秒").tag(seconds)
                    }
                }
                .disabled(!prefs.blockerEnabled)
            } footer: {
                Text("被标记为分心的分类会触发拦截。可在「分类」中修改。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("从不拦截") {
                if prefs.blockerAllowList.isEmpty {
                    Text("你标记为「不算分心」的应用和网站会出现在这里。")
                        .foregroundStyle(.secondary)
                }
                ForEach(prefs.blockerAllowList, id: \.self) { key in
                    RemovableRow {
                        AllowListLabel(key: key)
                    } onRemove: {
                        prefs.blockerAllowList.removeAll { $0 == key }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Allow-list keys are classification keys: `bundleID` or `bundleID|domain`.
private struct AllowListLabel: View {
    let key: String

    var body: some View {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            Label(parts[1], systemImage: "globe")
        } else {
            AppLabel(bundleID: parts[0])
        }
    }
}

// MARK: - Data

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @State private var exportMessage: String?

    private var dataFolder: URL { WeftSchema.dataFolder }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("导出 CSV…", action: exportCSV)
                } label: {
                    Text("导出全部活动")
                    Text("每条记录包含应用、标题、网址和分类。")
                }
                if let exportMessage {
                    Text(exportMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([dataFolder]) }
                } label: {
                    Text("数据文件夹")
                    Text("所有数据都留在这台 Mac 上：\(dataFolder.path(percentEncoded: false))")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "weft-activity.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(sortBy: [SortDescriptor(\.start)]))) ?? []
        let iso = ISO8601DateFormatter()
        var csv = "start,end,duration_seconds,app,bundle_id,domain,title,url,category,classification\n"
        for segment in segments {
            let fields: [String] = [
                iso.string(from: segment.start), iso.string(from: segment.end), String(Int(segment.duration)),
                segment.appName, segment.bundleID, segment.domain ?? "", segment.title ?? "", segment.url ?? "",
                model.classifier.category(segment.categoryKey).name, segment.classificationSourceRaw,
            ]
            csv += fields.map(Self.csvEscape).joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "已导出 \(segments.count) 条记录。"
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
