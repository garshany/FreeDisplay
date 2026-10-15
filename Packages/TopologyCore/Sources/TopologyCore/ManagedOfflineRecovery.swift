import DisplayDomain
import Foundation
import ProviderInterfaces

/// Reconnect All worked from the persisted managed-offline ledger, for a surface that has no app
/// model to ask (the Reconnect All intent when the app's model isn't there). A freshly composed
/// `CommandGateway` can't do it: its coordinator sees only the provider snapshot's offline list,
/// which `CoreGraphicsProvider` never fills, so it answered "nothing to reconnect" while the ledger
/// still held every display the app had turned off. The same rules the app and the CLI's `recover`
/// follow: accepted is not back (issue #40), and the ledger entry is the only record that a dark
/// display exists, so it goes only once its display is observed lit.
public enum ManagedOfflineRecovery {
    /// How one verified reconnect ended.
    public enum Attempt: Hashable, Sendable {
        /// The display was observed lit again.
        case lit
        /// macOS accepted the request but the display never came back.
        case notLit
        /// macOS refused the request.
        case rejected(String)
    }

    /// The ledger after one attempt on `offline`: forgotten once lit, kept stamped
    /// (`reconnectFailedAt`) when it never came back — the off card says so — and kept as it was
    /// when macOS refused.
    public static func ledger(_ ledger: [ManagedOfflineDisplay], after attempt: Attempt,
                              on offline: ManagedOfflineDisplay, at now: Date) -> [ManagedOfflineDisplay] {
        switch attempt {
        case .lit:
            return ledger.filter { $0.recordID != offline.recordID }
        case .notLit:
            return ledger.map { entry in
                guard entry.recordID == offline.recordID else { return entry }
                var stamped = entry
                stamped.reconnectFailedAt = now
                return stamped
            }
        case .rejected:
            return ledger
        }
    }

    /// Tries every entry of `ledger` in turn and saves the ledger after each one, so an interrupted
    /// run never loses a record. Returns one result per entry, in ledger order — the shape
    /// `ResultEnvelope.reconnectAll` takes.
    public static func reconnectAll(
        ledger: [ManagedOfflineDisplay],
        attempt: @Sendable (ManagedOfflineDisplay) async -> Attempt,
        save: @Sendable ([ManagedOfflineDisplay]) -> Void,
        now: @Sendable () -> Date = { Date() }
    ) async -> [(displayId: String, reconnected: Bool)] {
        var remaining = ledger
        var results: [(displayId: String, reconnected: Bool)] = []
        for offline in ledger {
            let outcome = await attempt(offline)
            remaining = Self.ledger(remaining, after: outcome, on: offline, at: now())
            save(remaining)
            results.append((offline.recordID.rawValue, outcome == .lit))
        }
        return results
    }

    /// One reconnect, verified the way the app's own is: ask the lifecycle provider, then watch the
    /// topology per `ReconnectVerification` — a patient wait, one `escalate` (the public
    /// permanent-configuration restore), a second wait. Cancelling ends the watch as `notLit`,
    /// which keeps the ledger entry: the display may still be dark.
    public static func verifiedAttempt(
        _ offline: ManagedOfflineDisplay, lifecycle: any LifecycleProvider, observer: any TopologyObserving,
        deadline: Date, escalate: @Sendable () -> Void
    ) async -> Attempt {
        do {
            try await lifecycle.reconnect(offline.reconnectID, deadline: deadline)
        } catch {
            return .rejected("\(error)")
        }
        var phaseStart = Date()
        var escalated = false
        while true {
            let observations = await observer.currentSnapshot().observations
            switch ReconnectVerification.next(isLit: ReconnectVerification.isLit(offline, in: observations),
                                              waited: Date().timeIntervalSince(phaseStart), escalated: escalated) {
            case .confirmed:
                return .lit
            case .failed:
                return .notLit
            case .lookAgain(let delay):
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return .notLit }
            case .escalate:
                escalated = true
                phaseStart = Date()
                escalate()
            }
        }
    }
}
