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
