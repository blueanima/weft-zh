import WeftKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "circle.circle").font(.system(size: 40)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("欢迎使用 Weft").font(.title.bold())
                    Text("自动记录时间，数据始终留在你的 Mac 上。").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                bullet("record.circle", "记录前台应用、窗口标题和浏览器网址——不截屏，不记录按键。")
                bullet("sparkles", "陌生的应用和网站由 Apple 的设备端模型分类，不会上传任何内容。")
                bullet("scope", "从菜单栏开始专注、会议或休息时段。")
            }

            Form {
                PermissionRow(
                    title: "辅助功能",
                    detail: "读取窗口标题所必需。",
                    granted: model.accessibilityGranted,
                    action: { SystemProbe.requestAccessibility(); SystemSettings.openAccessibility() }
                )
                LabeledContent {
                    switch model.classifier.aiAvailability {
                    case .available: Label("可用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable: Button("打开设置") { SystemSettings.openAppleIntelligence() }
                    }
                } label: {
                    Text("Apple 智能")
                    switch model.classifier.aiAvailability {
                    case .available: Text("已就绪，可进行设备端分类。")
                    case .unavailable(let reason): Text("\(reason)内置规则仍然可用。")
                    }
                }
                LabeledContent("浏览器") {
                    Text("每个浏览器会询问一次权限。").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 210)

            HStack {
                Spacer()
                Button("开始使用") {
                    model.preferences.hasCompletedOnboarding = true
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .task {
            // Pick up the Accessibility grant without requiring a relaunch.
            while !Task.isCancelled && !model.accessibilityGranted {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissions()
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
        }
    }
}
