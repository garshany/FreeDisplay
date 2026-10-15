import DisplayDomain
import Foundation

/// Edge-triggered policy for "auto-disconnect the built-in panel when an external connects" (Issue 5)
/// — the project's original use case, made automatic.
///
/// It fires only on the **rising edge** of external presence (none → some): the moment the first
/// external arrives is when the built-in should turn off. Plugging in a *second* external (some →
/// more) leaves presence "some", so no new edge fires and the built-in isn't disturbed again. Pure
/// decision logic — actually turning the built-in off (through the gated coordinator) and bringing it
/// back when the last external leaves (the existing always-one-active safety net) are the host's job.
public struct AutoDisconnectBuiltInPolicy {
    /// Auto-disconnect needs a native physical recovery surface. Keep-awake deliberately uses
    /// its broader external-presence predicate, since a DisplayLink screen also needs power.
    public static func eligibleExternalPresent(in observations: [DisplayObservation]) -> Bool {
        observations.contains { [DisplayClass.external, .projector, .television].contains($0.displayClass)
                && $0.physicalPresence == .physical && $0.isActive }
    }

    private var pendingArrival = false
    private var externalPresent: Bool

    public init(externalPresent: Bool = false) {
        self.externalPresent = externalPresent
    }

    /// Re-seed the tracked presence *without* firing — e.g. to the launch topology — so the next
    /// change is compared against the true prior state and an already-connected external isn't
    /// mistaken for a fresh arrival.
    public mutating func seed(externalPresent: Bool) {
        self.externalPresent = externalPresent
        pendingArrival = false
    }

    /// Observe every topology, independently of when configured reactions are allowed to run.
    public mutating func observe(enabled: Bool, externalPresent: Bool, suppressed: Bool) {
        let arrived = onTopologyChange(enabled: enabled, externalPresent: externalPresent)
        if !enabled || !externalPresent || suppressed { pendingArrival = false }
        else { pendingArrival = pendingArrival || arrived }
    }

    public mutating func takePendingArrival() -> Bool {
        let pending = pendingArrival
        pendingArrival = false
        return pending
    }

    /// Feed the latest `(enabled, externalPresent)` on every topology change. Returns true exactly when
    /// an external just arrived (none → some) while the policy is enabled — the moment to turn the
    /// built-in off. Always updates the tracked presence (even when disabled) so edges stay accurate.
    public mutating func onTopologyChange(enabled: Bool, externalPresent: Bool) -> Bool {
        let arrived = !self.externalPresent && externalPresent
        self.externalPresent = externalPresent
        return enabled && arrived
    }

    /// Command recorded when the policy fires. On a wake the external's re-arrival edge can fire
    /// this before the wake re-assert gets its turn, so an unaudited firing reads as the re-assert
    /// acting silently — the exact confusion the entry exists to prevent.
    public static let auditCommand = "autoDisconnect"

    /// The audit entry for one firing. `system` actor, like Protected Layout's restores: the app
    /// acted on its own, on the user's standing instruction.
    public static func auditEntry(builtIn: DisplayRecordID, committed: Bool,
                                  at now: Date) -> AuditEntry {
        AuditEntry(timestamp: now, actor: .system, command: auditCommand,
                   transactionId: "txn_\(auditCommand)",
                   status: committed ? "committed" : "failed",
                   targets: [builtIn.rawValue])
    }
}
