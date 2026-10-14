#if os(macOS)
import DisplayDomain
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

    /// Delivers `notification` as given — callers pass text already in the interface language
    /// (the builders below), never the packages' English wording.
    static func post(_ notification: NotificationPolicy.DisplayNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Wording in the interface language
    //
    // The packages also build on Linux, so they word their notifications in English only, with the
    // display names already inside the text. These builders word the same decisions from the
    // policies' structured data instead; each mirrors the package text it replaces.

    /// `NotificationPolicy.Event.notification`.
    static func notification(for event: NotificationPolicy.Event) -> NotificationPolicy.DisplayNotification {
        switch event {
        case .connected(let name):
            return .init(title: String(localized: "Display connected"),
                         body: name ?? String(localized: "A display"))
        case .disconnected(let name):
            return .init(title: String(localized: "Display disconnected"),
                         body: name ?? String(localized: "A display"))
        case .builtInAutoDisconnected:
            return .init(title: String(localized: "Built-in display turned off"),
                         body: String(localized: "Turned off automatically because an external display connected."))
        }
    }

    /// `XDRPowerAutomation.notificationTitle` + `SuspensionReason.notificationBody`; nil exactly
    /// where the package's body is nil (the built-in going away stays silent by design).
    static func notification(for reason: XDRPowerAutomation.SuspensionReason) -> NotificationPolicy.DisplayNotification? {
        let body: String
        switch reason {
        case .onBattery: body = String(localized: "Now running on battery power.")
        case .lowBattery(let percent): body = String(localized: "Battery at \(percent)%.")
        case .lowPowerMode: body = String(localized: "Low Power Mode is on.")
        case .autoOffTimer: body = String(localized: "The auto-off timer elapsed.")
        case .builtInInactive: return nil
        }
        return .init(title: String(localized: "XDR Brightness turned off"), body: body)
    }

    /// `ReconnectVerification.failureNotification(for:)`.
    static func reconnectFailureNotification(for offline: ManagedOfflineDisplay) -> NotificationPolicy.DisplayNotification {
        .init(title: String(localized: "\(offline.name) didn’t come back on"),
              body: String(localized: "OpenDisplay asked macOS to turn it on and nothing appeared. It is still listed in the menu, with recovery steps."))
    }

    /// `LayoutProtectionPolicy.restoreNotification(for:names:enabled:)`: what moved, per display,
    /// from the policy's structured drift.
    static func layoutRestoreNotification(for analysis: DisplayConfigDrifter.DriftAnalysis,
                                          names: [DisplayRecordID: String],
                                          enabled: Bool) -> NotificationPolicy.DisplayNotification? {
        // The package decides whether there is anything to say; only the wording is redone here.
        guard LayoutProtectionPolicy.restoreNotification(for: analysis, names: names, enabled: enabled) != nil
        else { return nil }
        let drift = LayoutProtectionPolicy.driftedFields(of: analysis, names: names)
        var parts = drift.displays.map { display in
            "\(display.name): \(display.fields.map(label(for:)).joined(separator: ", "))"
        }
        if drift.mainMoved { parts.append(String(localized: "main display")) }
        return .init(title: String(localized: "Restored your protected layout"),
                     body: parts.joined(separator: " · "))
    }

    /// `LayoutProtectionPolicy.failureNotification(enabled:)`.
    static func layoutRestoreFailureNotification(enabled: Bool) -> NotificationPolicy.DisplayNotification? {
        guard LayoutProtectionPolicy.failureNotification(enabled: enabled) != nil else { return nil }
        return .init(title: String(localized: "Couldn’t restore your protected layout"),
                     body: String(localized: "macOS kept the arrangement it had. Protect the current layout again to accept it."))
    }

    private static func label(for field: LayoutProtectionPolicy.DriftedField) -> String {
        switch field {
        case .position: return String(localized: "position")
        case .resolution: return String(localized: "resolution")
        case .rotation: return String(localized: "rotation")
        case .mirroring: return String(localized: "mirroring")
        case .onOff: return String(localized: "on/off")
        }
    }
}
#endif
