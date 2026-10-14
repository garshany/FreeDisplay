import DisplayDomain
import Foundation

/// Decides which display-topology transitions warrant a user notification, and the text (Batch-2 #5).
/// Pure decision logic (exercised by `make test`); the macOS layer posts the results via
/// `UNUserNotificationCenter`. Naturally de-duplicated: it diffs the prior vs current snapshot, so an
/// unchanged topology produces nothing, and each connect/disconnect fires once per real transition.
public enum NotificationPolicy {
    public struct DisplayNotification: Hashable, Sendable {
        public let title: String
        public let body: String
        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// One notable transition, as data rather than text, so a host can word it in the user's
    /// language. `name` is the display's user-facing name, nil when none resolved.
    public enum Event: Hashable, Sendable {
        case connected(name: String?)
        case disconnected(name: String?)
        /// The built-in was just turned off by the auto-disconnect policy (Issue 5).
        case builtInAutoDisconnected

        /// The event worded in English — what `notifications(...)` returns.
        public var notification: DisplayNotification {
            switch self {
            case .connected(let name):
                return DisplayNotification(title: "Display connected", body: name ?? "A display")
            case .disconnected(let name):
                return DisplayNotification(title: "Display disconnected", body: name ?? "A display")
            case .builtInAutoDisconnected:
                return DisplayNotification(
                    title: "Built-in display turned off",
                    body: "Turned off automatically because an external display connected."
                )
            }
        }
    }

    /// Notifications for the transition from `prior` to `current`. Empty when disabled or nothing
    /// notable changed. `names` resolves a display id to its user-facing name (alias → model → id);
    /// `builtInAutoDisconnected` is set when the built-in was just turned off by the auto-disconnect
    /// policy (Issue 5) so it can be announced distinctly from a plain disconnect.
    public static func notifications(
        prior: [DisplayObservation],
        current: [DisplayObservation],
        names: [DisplayRecordID: String],
        builtInAutoDisconnected: Bool = false,
        enabled: Bool
    ) -> [DisplayNotification] {
        events(prior: prior, current: current, names: names,
               builtInAutoDisconnected: builtInAutoDisconnected, enabled: enabled).map(\.notification)
    }

    /// The same decision as `notifications(...)`, before it is put into words.
    public static func events(
        prior: [DisplayObservation],
        current: [DisplayObservation],
        names: [DisplayRecordID: String],
        builtInAutoDisconnected: Bool = false,
        enabled: Bool
    ) -> [Event] {
        guard enabled else { return [] }

        let priorExternals = Set(prior.filter { $0.displayClass != .builtIn }.map(\.recordID))
        let currentExternals = Set(current.filter { $0.displayClass != .builtIn }.map(\.recordID))

        var result: [Event] = []
        // Connected: external present now, absent before — in a stable order.
        for id in currentExternals.subtracting(priorExternals).sorted(by: { $0.rawValue < $1.rawValue }) {
            result.append(.connected(name: names[id]))
        }
        // Disconnected: external present before, absent now.
        for id in priorExternals.subtracting(currentExternals).sorted(by: { $0.rawValue < $1.rawValue }) {
            result.append(.disconnected(name: names[id]))
        }
        if builtInAutoDisconnected {
            result.append(.builtInAutoDisconnected)
        }
        return result
    }
}

/// How OpenDisplay shows the notices it decides to send (SO-12). Independent of the OSD and of
/// action confirmations, which keep their own presentation whatever is chosen here.
public enum NotificationStyle: String, Hashable, Sendable, Codable, CaseIterable {
    /// macOS Notification Center. Needs the user's permission, which macOS can deny or withdraw
    /// at any time — the app reports that state rather than assuming delivery.
    case notificationCenter
    /// OpenDisplay's own notice window. Involves no system permission.
    case appWindow
}

extension NotificationPolicy {
    /// What a notice is about — the one thing the delivery filter needs to know about it.
    public enum NoticeKind: Hashable, Sendable {
        /// A topology or feature event: a display connected or left, the built-in was turned off
        /// automatically, an XDR boost was switched off.
        case event
        /// Routine confirmation that configuration protection did its job ("Restored your
        /// protected layout"). The only kind the protection-notice switch mutes.
        case routineProtection
        /// Something OpenDisplay or protection tried didn't work. Never muted by the
        /// protection-notice switch: a silent failure is the case notices exist for.
        case failure
    }

    /// Whether a notice of `kind` is delivered at all under `settings` (FA-16). Muting routine
    /// protection notices changes only what is said — restoration itself runs either way.
    public static func shouldDeliver(_ kind: NoticeKind, settings: OpenDisplaySettings) -> Bool {
        guard settings.displayNotificationsEnabled else { return false }
        switch kind {
        case .event, .failure: return true
        case .routineProtection: return settings.routineProtectionNoticesEnabled
        }
    }
}
