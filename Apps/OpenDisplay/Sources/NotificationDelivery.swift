#if os(macOS)
import Foundation
import TopologyCore
import UserNotifications

/// Thin wrapper over `UNUserNotificationCenter` for the display notifications (Batch-2 #5). The
/// decision of *what* to notify is the pure `NotificationPolicy`; this only delivers. Best-effort:
/// authorization failures and add() errors are ignored (no notification is just no notification).
enum NotificationDelivery {
    /// Requests notification authorization once (shows the system prompt the first time). Called when
    /// the feature is enabled, so a user who never turns it on is never prompted.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ notification: NotificationPolicy.DisplayNotification) {
        let content = UNMutableNotificationContent()
        switch notification.title {
        case "Display connected": content.title = "Дисплей подключён"
        case "Display disconnected": content.title = "Дисплей отключён"
        case "Built-in display turned off": content.title = "Встроенный дисплей выключен"
        default: content.title = notification.title
        }
        switch notification.body {
        case "A display": content.body = "Дисплей"
        case "Turned off automatically because an external display connected.":
            content.body = "Выключен автоматически после подключения внешнего дисплея."
        default: content.body = notification.body
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
#endif
