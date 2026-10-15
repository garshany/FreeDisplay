import DisplayDomain
import Foundation

/// Checks that a display the user asked to turn back on actually came back (issue #40).
///
/// A logical re-enable reports success when the window server *accepts* the request, not when a
/// picture appears. On some setups it never does: macOS restores a saved configuration for that
/// display that the link can no longer carry and gives up, leaving a monitor that is plugged in,
/// powered, and absent from every display list. Taking "accepted" for "back" is what let the app
/// drop its only record of such a display — the off card vanished while the screen stayed black.
///
/// So the reconnect is judged by the observed topology. The caller looks, and this decides what
/// the look means: done, look again shortly, try the stronger public restore once, or give up and
/// say so. ::
///
///     next(isLit: true, …)                          ok: .confirmed — forget the off record
///     next(isLit: false, waited: 2, escalated: no)  ok: .lookAgain — links take seconds to train
///     next(isLit: false, waited: 10, escalated: no) ok: .escalate — restore the permanent config
///     next(isLit: false, waited: 10, escalated: yes) flag: .failed — keep the record, tell the user
public enum ReconnectVerification {
    public enum Step: Hashable, Sendable {
        case confirmed
        case lookAgain(after: TimeInterval)
        case escalate
        case failed
    }

    /// How long one phase waits for the display. A Thunderbolt dock or a DSC link can take several
    /// seconds to train; escalating early would fire the system-wide restore at a display that was
    /// merely slow, and that restore also relights every other display the app is holding off.
    public static let settleTimeout: TimeInterval = 10
    public static let pollStep: TimeInterval = 0.5

    /// `waited` is the time spent in the current phase — the caller restarts it after escalating.
    public static func next(isLit: Bool, waited: TimeInterval, escalated: Bool,
                            settleTimeout: TimeInterval = settleTimeout,
                            pollStep: TimeInterval = pollStep) -> Step {
        if isLit { return .confirmed }
        if waited < settleTimeout { return .lookAgain(after: pollStep) }
        return escalated ? .failed : .escalate
    }

    /// Whether the turned-off display is a real, lit surface again — the display the entry recorded
    /// (`ReconnectIdentity.isSameDisplay`), not whatever now goes by its old display number. A lit
    /// display matching only by number used to count, and that is how another monitor that had
    /// been handed the number deleted the dark display's only record.
    public static func isLit(_ offline: ManagedOfflineDisplay,
                             in observations: [DisplayObservation]) -> Bool {
        WakeConvergencePolicy.visibleSurfaces(in: observations).contains {
            ReconnectIdentity.isSameDisplay($0, as: offline)
        }
    }

    /// The ledger to keep after the quit-time "reconnect everything": each entry whose display is
    /// not observed lit stays, stamped as a failed reconnect.
    ///
    /// Quitting used to clear the whole ledger once the reconnect requests had been *sent*, whatever
    /// they achieved — and the ledger is the only record that a turned-off display exists (it is
    /// absent from every display list). A display that stayed dark then had nothing left to show it
    /// in the menu, nothing for the CLI to reconnect, and nothing for the next launch's safety net to
    /// light. The kept entry is owed ON now, not off: `reconnectFailedAt` makes the off card say so
    /// and keeps the wake re-assert away from it, and a stale wake stamp is dropped for the same
    /// reason. An entry kept only because its display was slow to light is dropped by the next
    /// launch, which forgets entries whose display is already back.
    public static func ledgerAfterQuitReconnect(_ ledger: [ManagedOfflineDisplay],
                                                observations: [DisplayObservation],
                                                at now: Date) -> [ManagedOfflineDisplay] {
        ledger.compactMap { entry in
            guard !isLit(entry, in: observations) else { return nil }
            var kept = entry
            kept.reconnectFailedAt = now
            kept.relitDuringWakeAt = nil
            return kept
        }
    }

    public static let failureAuditCommand = "reconnectUnverified"
    public static let escalateAuditCommand = "reconnectEscalate"

    /// The audit entry for a reconnect that was accepted (or refused) but produced no display.
    public static func failureAudit(of offline: ManagedOfflineDisplay, actor: Actor,
                                    at now: Date) -> AuditEntry {
        AuditEntry(timestamp: now, actor: actor, command: failureAuditCommand,
                   transactionId: "txn_\(failureAuditCommand)", status: "failed",
                   targets: [offline.recordID.rawValue])
    }

    /// The audit entry for the one escalation to the permanent-configuration restore.
    public static func escalateAudit(of offline: ManagedOfflineDisplay, actor: Actor,
                                     at now: Date) -> AuditEntry {
        AuditEntry(timestamp: now, actor: actor, command: escalateAuditCommand,
                   transactionId: "txn_\(escalateAuditCommand)", status: "attempted",
                   targets: [offline.recordID.rawValue])
    }

    public static func failureNotification(
        for offline: ManagedOfflineDisplay
    ) -> NotificationPolicy.DisplayNotification {
        NotificationPolicy.DisplayNotification(
            title: "\(offline.name) didn\u{2019}t come back on",
            body: "OpenDisplay asked macOS to turn it on and nothing appeared. It is still listed "
                + "in the menu, with recovery steps.")
    }

    /// Where the off card's "Recovery steps" link goes.
    public static let recoveryGuideURL = URL(
        string: "https://github.com/aquitaine/OpenDisplay/blob/main/Docs/Recovering-a-stranded-display.md")!
}
