import Foundation
@preconcurrency import UserNotifications

public enum NotificationAction: String, Sendable {
    case startBreak = "START_BREAK"
    case snooze = "SNOOZE"
    case backToWork = "BACK_TO_WORK"
    case notADistraction = "NOT_A_DISTRACTION"
}

public enum NotificationKind: String, Sendable {
    case breakReminder = "BREAK_REMINDER"
    case distraction = "DISTRACTION"
    case sessionEnded = "SESSION_ENDED"
    case workHours = "WORK_HOURS"
}

@MainActor
public protocol NotificationPosting: AnyObject {
    func post(_ kind: NotificationKind, title: String, body: String)
}

/// Local notifications with action buttons. Actions are routed back through `onAction`.
@MainActor
public final class Notifier: NSObject, NotificationPosting {
    public var onAction: ((NotificationAction) -> Void)?
    private let center = UNUserNotificationCenter.current()

    public override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: NotificationKind.breakReminder.rawValue,
                actions: [
                    UNNotificationAction(identifier: NotificationAction.startBreak.rawValue, title: "开始休息"),
                    UNNotificationAction(identifier: NotificationAction.snooze.rawValue, title: "稍后提醒"),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: NotificationKind.distraction.rawValue,
                actions: [
                    UNNotificationAction(identifier: NotificationAction.backToWork.rawValue, title: "回到工作"),
                    UNNotificationAction(identifier: NotificationAction.notADistraction.rawValue, title: "不算分心"),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    public func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func post(_ kind: NotificationKind, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = kind.rawValue
        // Reusing the identifier replaces an older notification of the same kind.
        center.add(UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil))
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let action = NotificationAction(rawValue: response.actionIdentifier) else { return }
        await MainActor.run { self.onAction?(action) }
    }
}
