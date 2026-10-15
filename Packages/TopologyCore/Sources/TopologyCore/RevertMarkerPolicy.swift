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
/// warning, every recorded display connected again, and the topology read back afterwards showing
/// every recorded mode, origin and mirror relationship that can still be judged. Until then it
/// stays, and the next launch restores it.
///
/// A recorded display that isn't connected is the case that slipped through: nothing can be written
/// to it and nothing about it read back, so a restore that skipped it had nothing wrong to report —
/// and a monitor that dropped out during a failed mode change, or was unplugged when the app
/// relaunched, lost its record to a "success". Such a restore is *not yet verified*
/// (`Disposition.awaitingDisplays`), and that is not verified: what is owed to those displays stays
/// on record (`recordToKeep`), the user is told the restore can't be confirmed yet, and the next
/// launch tries again. Only what is owed: the connected displays did verify, and re-applying their
/// old settings at every launch would undo whatever was changed since outside the app. And never a
/// window-server-only screen (OpenDisplay's own virtual displays, macOS's placeholder): those come
/// back under a new identity if at all, so waiting for one would keep the record for good.
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
        /// A recorded display isn't connected: nothing was restored on it, and its restore can't be
        /// judged until it is back.
        case absent(DisplayRecordID)
    }

    /// How a keep/revert window — or a restore outside one — ended.
    public enum Outcome: Hashable, Sendable {
        /// The user kept the settings on screen: there is nothing left to restore.
        case kept
        /// A restore ran. `providerWarnings` are what the arrangement write reported; `mismatches`
        /// what the readback afterwards still shows wrong.
        case restored(providerWarnings: [String], mismatches: [Mismatch])
    }

    /// What of `wanted` the topology `current` doesn't show:
    /// - **absent**, for a recorded display `current` doesn't list — the one thing a restore can't
    ///   be judged on yet, rather than a thing it got right. Not for a window-server-only screen
    ///   (`PhysicalPresence.virtual`, or the `.virtual` placeholder class), which can't be awaited;
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
            guard let now = live[recorded.recordID] else {
                if !isWindowServerOnly(recorded) { result.append(.absent(recorded.recordID)) }
                continue
            }
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

    /// What becomes of the recovery record after `outcome`, and what the user is told.
    public enum Disposition: Hashable, Sendable {
        /// The settings were kept, or the restore verified: the record may go.
        case clear
        /// Everything connected shows as recorded and the write reported nothing, but these recorded
        /// displays aren't connected, so the restore can't be confirmed yet. What is owed to them
        /// stays on record (`recordToKeep`) — across launches too — and is restored at the next one.
        case awaitingDisplays([DisplayRecordID])
        /// The write reported a problem or a connected display shows something other than recorded.
        /// The record stays.
        case unverified
    }

    public static func disposition(after outcome: Outcome) -> Disposition {
        switch outcome {
        case .kept:
            return .clear
        case .restored(let warnings, let mismatches):
            guard warnings.isEmpty else { return .unverified }
            var absent: [DisplayRecordID] = []
            for mismatch in mismatches {
                guard case .absent(let id) = mismatch else { return .unverified }
                absent.append(id)
            }
            return absent.isEmpty ? .clear : .awaitingDisplays(absent)
        }
    }

    /// Whether the recovery record may be deleted after `outcome`.
    public static func mayClearMarker(after outcome: Outcome) -> Bool {
        disposition(after: outcome) == .clear
    }

    /// The record to keep after a restore of `recorded` ended in `outcome`, or nil when it may go.
    /// Whole when the restore didn't verify on a connected display. When all it lacks is displays
    /// that aren't connected, just what is owed to them: their recorded state, and that of any
    /// display recorded as mirroring one of them, whose mirror couldn't be put back or judged either.
    public static func recordToKeep(_ recorded: [DisplayObservation],
                                    after outcome: Outcome) -> [DisplayObservation]? {
        switch disposition(after: outcome) {
        case .clear:
            return nil
        case .unverified:
            return recorded
        case .awaitingDisplays(let ids):
            let awaited = Set(ids)
            return recorded.filter {
                awaited.contains($0.recordID) || $0.mirrorSourceID.map(awaited.contains) == true
            }
        }
    }

    /// A screen that exists only inside the window server. Older records carry no presence; their
    /// class still names macOS's placeholder.
    private static func isWindowServerOnly(_ observation: DisplayObservation) -> Bool {
        observation.physicalPresence == .virtual || observation.displayClass == .virtual
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
