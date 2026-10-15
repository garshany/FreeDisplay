import DisplayDomain
import Foundation

/// The keep/revert window's recovery record (`revert.pending`): when it may go, and what a restore
/// has to show before it does. Pure, so the retention rules are unit-tested; the app reads the
/// topology, performs the writes and owns the file.
///
/// The record is the only thing that remembers the arrangement a rejected rollback failed to put
/// back. Deleting it because a countdown ended, or because the restore was *requested*, is how a
/// bad mode or mirror set could outlive its own rescue with nothing left to recover it from. So it
/// goes only when the user keeps the settings on screen, or when a restore is verified: no provider
/// warning, and the topology read back afterwards shows every recorded mode, origin and mirror
/// relationship that can still be judged. Until then it stays, and the next launch restores it.
///
/// A new display change the user starts replaces it with its own record of the arrangement on
/// screen: its keep/revert window must go back to what the user was looking at when they made it —
/// a record that failed to restore once may well fail again (a mode the display no longer offers),
/// and reverting to it would leave the new change standing.
public enum RevertMarkerPolicy {
    /// One way the readback differs from the arrangement a restore asked for.
    public enum Mismatch: Hashable, Sendable {
        case mode(DisplayRecordID)
        case origin(DisplayRecordID)
        case mirror(DisplayRecordID)
    }

    /// How a keep/revert window — or a restore outside one — ended.
    public enum Outcome: Hashable, Sendable {
        /// The user kept the settings on screen: there is nothing left to restore.
        case kept
        /// A restore ran. `providerWarnings` are what the arrangement write reported; `mismatches`
        /// what the readback afterwards still shows wrong.
        case restored(providerWarnings: [String], mismatches: [Mismatch])
    }

    /// What of `wanted` the topology `current` doesn't show, per display present in both — one that
    /// is gone can't be restored, and isn't showing anything wrong either:
    /// - **mode**, exactly (`DisplayModeChoices.matches`), when one was recorded;
    /// - **mirror source** (or independence), unless the recorded source is gone — a missing source
    ///   can't be substituted (`MirrorRestorePlan` drops that step), so it can't be owed;
    /// - **origin**, only while exactly the recorded displays are present, and never for a mirror
    ///   target (recorded or current), which sits wherever its source is. With a display gone or
    ///   new, macOS re-packs the rest, and the recorded positions are no longer ones it can be held to.
    public static func mismatches(wanted: [DisplayObservation],
                                  current: [DisplayObservation]) -> [Mismatch] {
        let live = Dictionary(current.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
        let present = Set(live.keys)
        let sameSet = Set(wanted.map(\.recordID)) == present
        var result: [Mismatch] = []
        for recorded in wanted {
            guard let now = live[recorded.recordID] else { continue }
            if let mode = recorded.mode,
               !(now.mode.map { $0 == mode || DisplayModeChoices.matches($0, requested: mode) } ?? false) {
                result.append(.mode(recorded.recordID))
            }
            let sourceJudgeable = recorded.mirrorSourceID.map(present.contains) ?? true
            if sourceJudgeable, now.mirrorSourceID != recorded.mirrorSourceID {
                result.append(.mirror(recorded.recordID))
            }
            // A mirror target on either side sits where its source is: its mirror state says it all.
            if sameSet, recorded.mirrorSourceID == nil, now.mirrorSourceID == nil,
               now.origin != recorded.origin {
                result.append(.origin(recorded.recordID))
            }
        }
        return result
    }

    /// Whether a restore is verified: the write reported nothing and the readback shows no mismatch.
    public static func isVerified(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .kept:
            return false  // nothing was restored
        case .restored(let warnings, let mismatches):
            return warnings.isEmpty && mismatches.isEmpty
        }
    }

    /// Whether the recovery record may be deleted after `outcome`.
    public static func mayClearMarker(after outcome: Outcome) -> Bool {
        outcome == .kept || isVerified(outcome)
    }

    /// The part of a recorded arrangement a restore may write and is judged on: every display except
    /// those the user has since turned off (`ledger`, the managed-offline displays). Turning a display
    /// off is the newer instruction — with the public lifecycle provider "off" IS a mirror onto main,
    /// so putting the recorded mirror state back would switch it on again, and the next refresh would
    /// then forget that it was ever owed off (the rule `LayoutProtectionPolicy.actionableDrift` keeps
    /// for the same reason).
    public static func restorable(_ recorded: [DisplayObservation],
                                  ledger: Set<DisplayRecordID>) -> [DisplayObservation] {
        recorded.filter { !ledger.contains($0.recordID) }
    }
}
