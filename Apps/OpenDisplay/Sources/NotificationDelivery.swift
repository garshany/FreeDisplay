#if os(macOS)
import AppKit
import DisplayDomain
import Foundation
import SwiftUI
import TopologyCore
import UserNotifications

/// Delivery for the display notifications (Batch-2 #5): macOS Notification Center or, by choice,
/// OpenDisplay's own notice window (SO-12). The decision of *what* to notify is the pure
/// `NotificationPolicy`; this only delivers. A failed Notification Center delivery doesn't retry —
/// it is recorded in `NotificationPermission` so Settings can say notices aren't arriving.
enum NotificationDelivery {
    /// Where `post` sends notices. Mirrors `OpenDisplaySettings.notificationStyle`; `AppModel`
    /// sets it at launch and on every change.
    @MainActor static var style: NotificationStyle = .notificationCenter

    /// Requests notification authorization once (shows the system prompt the first time). Called when
    /// the feature is enabled, so a user who never turns it on is never prompted.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in
            Task { @MainActor in NotificationPermission.shared.refresh() }
        }
    }

    /// Delivers `notification` as given — callers pass text already in the interface language
    /// (the builders below), never the packages' English wording.
    @MainActor static func post(_ notification: NotificationPolicy.DisplayNotification) {
        switch style {
        case .appWindow:
            NoticeWindowController.shared.show(notification)
        case .notificationCenter:
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { @Sendable error in
                let message = error?.localizedDescription
                Task { @MainActor in NotificationPermission.shared.noteDelivery(error: message) }
            }
        }
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

    /// `ReconnectVerification.failureNotification(for:)`, worded for the operation that is being
    /// undone: a disconnected display didn't reappear, a mirrored one is still mirrored. Neither was
    /// ever powered off, so neither is described as failing to "turn on".
    static func reconnectFailureNotification(for offline: ManagedOfflineDisplay,
                                             method: LogicalOffMethod) -> NotificationPolicy.DisplayNotification {
        switch method {
        case .disconnect:
            return .init(title: String(localized: "\(offline.name) didn’t reconnect"),
                         body: String(localized: "OpenDisplay asked macOS to reconnect it and the display didn’t appear. It is still listed in the menu, with recovery steps."))
        case .mirror:
            return .init(title: String(localized: "\(offline.name) is still mirrored"),
                         body: String(localized: "OpenDisplay asked macOS to stop mirroring it and it didn’t return to the desktop. It is still listed in the menu, with recovery steps."))
        }
    }

    /// A reconnect OpenDisplay didn't send: the display number the turned-off display was recorded
    /// under now names another display (`ReconnectIdentity`), and sending it could have reached that
    /// one instead.
    static func reconnectRefusedNotification(for offline: ManagedOfflineDisplay) -> NotificationPolicy.DisplayNotification {
        .init(title: String(localized: "\(offline.name) wasn’t reconnected"),
              body: String(localized: "Its display number now belongs to another display, so OpenDisplay didn’t send the request — it could have reached the wrong screen. It is still listed in the menu, with recovery steps."))
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

// MARK: - Notification permission (SO-12/FA-16)

/// What macOS currently allows for OpenDisplay's notifications — the effective permission, which
/// is separate from the saved preference and can change in System Settings without the app being
/// told. Re-read whenever Settings shows it or the app comes forward. Purely informational:
/// nothing else in the app (brightness, modes, recovery) depends on it.
@MainActor
final class NotificationPermission: ObservableObject {
    static let shared = NotificationPermission()

    enum State: Equatable {
        /// Not read yet.
        case unknown
        /// macOS hasn't asked the user yet.
        case notRequested
        /// Turned off for OpenDisplay in System Settings (or declined at the prompt).
        case denied
        /// Allowed, with banners or alerts.
        case allowed
        /// Allowed, but with the alert style set to None: notices land in Notification Center
        /// without appearing on screen.
        case allowedQuietly
        /// Delivered quietly until the user decides (provisional authorization).
        case provisional
    }

    @Published private(set) var state: State = .unknown
    /// The error macOS gave for the last Notification Center delivery, nil once one succeeds.
    @Published private(set) var lastDeliveryError: String?

    private init() {}

    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
            let state = Self.state(authorization: settings.authorizationStatus, alertStyle: settings.alertStyle)
            Task { @MainActor in
                let permission = NotificationPermission.shared
                if permission.state != state { permission.state = state }
            }
        }
    }

    func noteDelivery(error: String?) {
        if lastDeliveryError != error { lastDeliveryError = error }
    }

    nonisolated private static func state(authorization: UNAuthorizationStatus,
                                          alertStyle: UNAlertStyle) -> State {
        switch authorization {
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .provisional: return .provisional
        case .authorized: return alertStyle == .none ? .allowedQuietly : .allowed
        @unknown default: return .unknown
        }
    }

    /// Opens OpenDisplay's page in System Settings › Notifications, or the Notifications list where
    /// the per-app page can't be addressed.
    static func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - OpenDisplay's own notice window (SO-12 "app window" style)

/// One floating window listing the notices posted while the "OpenDisplay window" style is chosen,
/// newest first, until the user clears or closes it. It never takes focus from the app being
/// used, and needs no system permission. Every notice stays listed until dismissed — nothing is
/// dropped to make room.
@MainActor
final class NoticeWindowController: NSObject, NSWindowDelegate {
    static let shared = NoticeWindowController()

    private let list = NoticeList()
    private var panel: NSPanel?

    func show(_ notification: NotificationPolicy.DisplayNotification) {
        list.items.insert(NoticeList.Item(title: notification.title, body: notification.body, date: Date()), at: 0)
        let panel = self.panel ?? makePanel()
        if !panel.isVisible, let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - NoticeLayout.inset,
                                         y: visible.maxY - size.height - NoticeLayout.inset))
        }
        panel.orderFrontRegardless()
    }

    /// Closed rather than ordered out, so `willClose` reaches everything that counts open windows
    /// (the Dock icon policy) exactly as when the user clicks the close button.
    func dismissAll() {
        list.items.removeAll()
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        list.items.removeAll()
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: NoticeListView(list: list) { [weak self] in self?.dismissAll() })
        // The window keeps the size it is given (and the user drags it to); the list scrolls.
        hosting.sizingOptions = []
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: NoticeLayout.initialSize),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.setContentSize(NoticeLayout.initialSize)
        panel.contentMinSize = NoticeLayout.minimumSize
        panel.title = String(localized: "OpenDisplay Notices")
        panel.level = .floating
        // A menu-bar app is rarely the active app; a panel that hid on deactivation would vanish
        // the moment it appeared.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        self.panel = panel
        return panel
    }
}

/// Window geometry for the notice window — its starting size and the corner gap.
private enum NoticeLayout {
    static let initialSize = NSSize(width: 360, height: 240)
    static let minimumSize = NSSize(width: 280, height: 140)
    static let inset: CGFloat = 16
}

@MainActor
private final class NoticeList: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let body: String
        let date: Date
    }
    @Published var items: [Item] = []
}

private struct NoticeListView: View {
    @ObservedObject var list: NoticeList
    let onDismissAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(list.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.title).font(.headline)
                                Spacer(minLength: 8)
                                Text(item.date.formatted(date: .omitted, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !item.body.isEmpty {
                                Text(item.body).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Dismiss All", action: onDismissAll)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
    }
}
#endif
