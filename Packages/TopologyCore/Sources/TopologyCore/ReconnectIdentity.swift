import DisplayDomain
import Foundation

/// Which display a turned-off display's reconnect may act on, and which observed display counts as
/// that display coming back.
///
/// A logically disabled display can only be reconnected by its raw Core Graphics number
/// (`ManagedOfflineDisplay.reconnectID`, `cgid:<n>`): the UUID route needs the display online, which
/// is exactly what it isn't. But the number is an address, not an identity. The ledger outlives the
/// session that wrote it, and macOS hands numbers out again — after a reboot, a dock replug, another
/// monitor enumerating first — so by the time an entry is reconnected its number can name another
/// display. Acting on it then writes to that display (the public provider un-mirrors it), and
/// taking its number for proof that the turned-off display came back deletes the ledger entry: the
/// only record that the dark display exists.
///
/// So identity is what the entry recorded — its `cg:<uuid>` record id — and the number is used only
/// while nothing contradicts it:
/// - an observed display is the entry's display when its persistent UUID is the recorded one, or —
///   where either side has no UUID — when its record id is the entry's (for a UUID-less entry, the
///   only identity it ever had). A matching number alone never is;
/// - a display still online under its recorded identity is reconnected at the number it has now;
/// - otherwise the recorded number is refused while an online display that isn't the entry's holds
///   it, while Core Graphics resolves it to a persistent UUID other than the recorded one, or while
///   a display turned off *after* this one recorded the same number — the number was handed on, and
///   the later record is its owner (the ledger is kept in the order displays were turned off). ::
///
///     entry cg:A #7, online cg:B #7         flag: refused — #7 is B's now; A's entry stays
///     entry cg:A #7, online cg:A #9         ok: A is lit — same UUID under a new number
///     entry cg:A #7, CG resolves #7 to B    flag: refused — the number names another display
///     ledger [cg:A #7, cg:B #7], both dark   flag: A refused — #7 went to B; ok: B reconnects
public enum ReconnectIdentity {
    /// Why the entry's display number can't be trusted to reach its display right now. Thrown in
    /// place of the reconnect, so every surface reports it as a refused request and keeps the entry.
    public enum Conflict: Error, Hashable, Sendable, CustomStringConvertible {
        /// An online display that isn't the entry's goes by the number.
        case numberHeldByAnotherDisplay(number: UInt32, holder: DisplayRecordID)
        /// Core Graphics resolves the number to a persistent UUID the entry didn't record.
        case numberNamesAnotherDisplay(number: UInt32, uuid: String)
        /// A display turned off after the entry's recorded the same number. Both are dark, so
        /// nothing live tells them apart, and the number reaches whichever holds it now — the later.
        case numberRecordedLaterForAnotherDisplay(number: UInt32, by: DisplayRecordID)

        public var description: String {
            switch self {
            case .numberHeldByAnotherDisplay(let number, let holder):
                return "display number \(number) now belongs to another display (\(holder.rawValue)); "
                    + "not reconnecting by number"
            case .numberNamesAnotherDisplay(let number, let uuid):
                return "display number \(number) now names another display (UUID \(uuid)); "
                    + "not reconnecting by number"
            case .numberRecordedLaterForAnotherDisplay(let number, let other):
                return "display number \(number) was recorded later for another turned-off display "
                    + "(\(other.rawValue)); not reconnecting by number"
            }
        }
    }

    /// Whether `observation` is the display `offline` recorded: the same persistent UUID, or — where
    /// either side has none — the same record id. Never the display number alone.
    public static func isSameDisplay(_ observation: DisplayObservation,
                                     as offline: ManagedOfflineDisplay) -> Bool {
        if let recorded = offline.recordID.cgUUID, let observed = persistentUUID(of: observation) {
            return sameUUID(recorded, observed)
        }
        return observation.recordID == offline.recordID
    }

    /// What to ask the lifecycle provider to reconnect for `offline`. The display's *current*
    /// number when it is online under its recorded identity — the public provider's "off" is a
    /// mirror, which leaves it enumerated, possibly under a number it got since; otherwise the
    /// recorded address (`reconnectID`), unless `conflict` forbids it, which is thrown instead.
    public static func reconnectTarget(for offline: ManagedOfflineDisplay, observations: [DisplayObservation],
                                       ledger: [ManagedOfflineDisplay],
                                       uuidForNumber: (UInt32) -> String?) throws -> DisplayRecordID {
        if let number = observations.first(where: { isSameDisplay($0, as: offline) })?.cgDisplayID {
            return DisplayRecordID(rawValue: "cgid:\(number)")
        }
        if let conflict = conflict(for: offline, observations: observations, ledger: ledger,
                                   uuidForNumber: uuidForNumber) {
            throw conflict
        }
        return offline.reconnectID
    }

    /// What forbids reconnecting `offline` by its recorded display number right now, or nil when
    /// nothing does. `observations` is the live topology; `ledger` the managed-offline ledger in its
    /// stored order (oldest turn-off first); `uuidForNumber` is Core Graphics' current answer for a
    /// number (`CGDisplayCreateUUIDFromDisplayID`), nil when it has none — a disabled display may not
    /// resolve, and no answer contradicts nothing. An entry without a number reconnects by its record
    /// id, which the provider resolves through the UUID itself.
    public static func conflict(for offline: ManagedOfflineDisplay, observations: [DisplayObservation],
                                ledger: [ManagedOfflineDisplay],
                                uuidForNumber: (UInt32) -> String?) -> Conflict? {
        guard offline.cgID != 0 else { return nil }
        if let holder = observations.first(where: {
            $0.cgDisplayID == offline.cgID && !isSameDisplay($0, as: offline)
        }) {
            return .numberHeldByAnotherDisplay(number: offline.cgID, holder: holder.recordID)
        }
        // Two connected displays never share a number, so of two entries recording it the earlier
        // one's display has left since, and the number went to the display turned off after it.
        if let position = ledger.firstIndex(where: { $0.recordID == offline.recordID }),
           let later = ledger[ledger.index(after: position)...].first(where: {
               $0.cgID == offline.cgID && $0.recordID != offline.recordID
           }) {
            return .numberRecordedLaterForAnotherDisplay(number: offline.cgID, by: later.recordID)
        }
        // An entry that recorded no UUID can't be matched to one: a number that now resolves to a
        // persistent identity is a display the entry can't be shown to be.
        if let resolved = uuidForNumber(offline.cgID),
           !(offline.recordID.cgUUID.map { sameUUID($0, resolved) } ?? false) {
            return .numberNamesAnotherDisplay(number: offline.cgID, uuid: resolved)
        }
        return nil
    }

    /// An observation's persistent identity: the UUID it carries, or the one inside its `cg:` id.
    static func persistentUUID(of observation: DisplayObservation) -> String? {
        observation.cgUUID ?? observation.recordID.cgUUID
    }

    /// Core Graphics spells UUIDs in upper case, but a hand-edited or older ledger needn't.
    static func sameUUID(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
