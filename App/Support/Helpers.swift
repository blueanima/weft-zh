import AppKit
import WeftKit
import ServiceManagement
import SwiftUI

extension Color {
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits, radix: 16) ?? 0x999999
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X",
                      Int(round(color.redComponent * 255)),
                      Int(round(color.greenComponent * 255)),
                      Int(round(color.blueComponent * 255)))
    }
}

extension CategoryDefinition {
    var color: Color { Color(hex: colorHex) }
}

extension Locale {
    /// 界面统一使用简体中文，日期、星期和数字格式也跟着走，不随系统语言变化。
    static let weftUI = Locale(identifier: "zh_Hans_CN")
}

enum Format {
    /// 3725 → "1 小时 2 分", 125 → "2 分", 20 → "20 秒"
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    /// Countdown style: "24:59" or "1:02:03".
    static func countdown(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    static func minutesLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分钟" : (minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分钟")
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = image
        return image
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Weft: launch at login change failed: \(error)")
        }
    }
}

enum SystemSettings {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomation() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openAppleIntelligence() {
        open("x-apple.systempreferences:com.apple.Siri-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// Renders its content only while on screen. A closed SwiftUI window keeps its view tree
/// alive, and a `@Query` inside keeps re-evaluating on every store change; dropping the
/// tree when hidden stops that work entirely.
struct OnlyWhileVisible<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isVisible = false

    var body: some View {
        ZStack {
            Color.clear
            if isVisible { content() }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}
