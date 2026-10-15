import DisplayDomain
import Foundation

/// Automatic forgetting of remembered displays that haven't been seen for a while (SD-09/SD-10,
/// FB-13). Off unless the user sets a number of days (`OpenDisplaySettings.rememberedDisplayRetentionDays`):
/// FreeDisplay keeps every record until the user forgets it, and chooses no period of its own.
///
/// The period is real elapsed time — whole days of 86 400 seconds since the display was last seen —
/// never a number of seconds mistaken for days. Only a registered record of a display that is simply
/// not connected can fall due; everything that is still someone's way back, or might be a display
/// that is here right now, is exempt:
/// - a connected display (it is seen on every refresh anyway),
/// - one OpenDisplay switched off, including one whose reconnect found nothing — its card is the
///   user's way back, and dropping it unasked would be the silent version of the warned-about forget,
/// - a display the registry couldn't tell apart from a connected look-alike, or a provisional one,
/// - a virtual screen's record (its definition outlives any one session),
/// - a record with no "last seen" date: its age is unknown, so it is never presumed old.
/// What falls due is forgotten exactly as a confirmed Forget would (`RememberedDisplayCleanup`).
public enum RememberedDisplayRetention {
    public static let secondsPerDay: TimeInterval = 86_400

    public enum Exemption: String, Hashable, Sendable, CaseIterable {
        case connected
        case turnedOffByApp
        case reconnectFailed
        case notRegistered
        case provisional
        case mayBeConnectedDisplay
        case virtualDisplay
        case unknownLastSeen
    }

    public enum Verdict: Hashable, Sendable {
        /// Automatic forgetting is off.
        case off
        /// Never forgotten automatically while this holds.
        case exempt(Exemption)
        /// Not due yet: forgotten automatically once this moment passes unseen.
        case keptUntil(Date)
        /// Unseen for at least the period since this moment: forget it.
        case due(since: Date)
    }

    /// The configured period, or nil when automatic forgetting is off. A period must be a whole
    /// number of days of at least one; anything else (zero, negative) means off rather than
    /// "forget immediately", which would erase short-term offline history.
    public static func normalizedDays(_ days: Int?) -> Int? {
        guard let days, days >= 1 else { return nil }
        return days
    }

    public static func verdict(for entry: RememberedDisplay, days: Int?, now: Date) -> Verdict {
        guard let days = normalizedDays(days) else { return .off }
        if let exemption = exemption(for: entry) { return .exempt(exemption) }
        guard let lastSeen = entry.record?.lastSeen else { return .exempt(.unknownLastSeen) }
        let deadline = lastSeen.addingTimeInterval(Double(days) * secondsPerDay)
        return now >= deadline ? .due(since: deadline) : .keptUntil(deadline)
    }

    /// The entries automatic forgetting removes now, in inventory order.
    public static func dueEntries(_ entries: [RememberedDisplay], days: Int?, now: Date) -> [RememberedDisplay] {
        entries.filter {
            if case .due = verdict(for: $0, days: days, now: now) { return true }
            return false
        }
    }

    private static func exemption(for entry: RememberedDisplay) -> Exemption? {
        switch entry.status {
        case .connected: return .connected
        case .turnedOff: return .turnedOffByApp
        case .reconnectFailed: return .reconnectFailed
        case .notConnected: break
        }
        guard entry.isRegistered, let record = entry.record else { return .notRegistered }
        if record.isProvisional { return .provisional }
        if entry.mayBeConnectedDisplay { return .mayBeConnectedDisplay }
        if record.displayClass == .virtual { return .virtualDisplay }
        return nil
    }
}
