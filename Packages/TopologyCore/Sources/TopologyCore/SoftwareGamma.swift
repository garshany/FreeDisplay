import DisplayDomain
import Foundation

/// Who holds a display's gamma (colour-table) slot and what the next software-image write must do
/// with it. Pure, so the "overlay never touches gamma" and "blocked gamma hands the slot back"
/// rules are unit-tested; the app performs the Core Graphics calls.
///
/// A "neutral" formula is not a bypass: writing an identity transfer still replaces the table the
/// display's ColorSync profile installed. So when nothing needs gamma, OpenDisplay makes no
/// colour-table call at all — or, if its own table is still there, releases only that display's
/// adjustment with an identity transfer. A global ColorSync restore would reset other apps too.
public enum GammaSlotPolicy {
    public enum Action: Hashable, Sendable {
        /// Express the composed dim × warmth × contrast × boost transfer (`SoftwareImageTransfer`).
        case write
        /// Clear only this display's owned adjustment: nothing may (or needs to) use it.
        case release
        /// No colour-table call: nothing needs gamma and ColorSync already owns the slot.
        case none
        /// Gamma is needed but blocked, and nothing of OpenDisplay's is installed: write nothing,
        /// report it.
        case blocked
    }

    /// `needsGamma`: the composed values differ from an untouched display. `owned`: OpenDisplay's
    /// table is what the display currently shows. `blocked`: gamma writes are not allowed right now.
    public static func action(needsGamma: Bool, owned: Bool, blocked: Bool) -> Action {
        if owned && (blocked || !needsGamma) { return .release }
        if !needsGamma { return .none }
        return blocked ? .blocked : .write
    }

    /// Whether a dim scale, warmth gains and XDR boost amount to anything other than the display's
    /// own calibration (contrast neutral). The composed transfer is the one definition of it.
    public static func needsGamma(dim: Float, gains: ColorTemperatureCurve.Gains, boost: Float) -> Bool {
        SoftwareImageTransfer(dim: dim, gains: gains, boost: boost).needsGamma
    }

    /// The dimming method actually used. While gamma is blocked the overlay carries the dim, so
    /// software dimming and software brightness keep working — the documented fallback.
    public static func effectiveMethod(_ method: DimmingMethod, gammaBlocked: Bool) -> DimmingMethod {
        gammaBlocked ? .overlay : method
    }
}

/// The default custom-profile safeguard blocks gamma only on the display carrying a user/shared
/// custom ICC profile (or whose assignment is still unknown), because colour-table
/// writes combined with such profiles can leave a screen black or tinted while it is still
/// connected. Factory and system profiles don't trigger it; an assignment ColorSync has not yet
/// reported for a connected display does, until it is read (fail closed — "couldn't read" is not
/// "factory"). The app can override it explicitly.
public enum ColorProfileGuard {
    public enum Assignment: Hashable, Sendable {
        /// No custom profile, or a display factory profile (this display's or another's).
        case factory
        /// A profile macOS itself ships.
        case system
        /// A user or shared custom profile file.
        case custom
    }

    /// Classifies the profile ColorSync reports as a display's custom assignment.
    public static func classify(assignedPath: String?, factoryPaths: [String]) -> Assignment {
        guard let assignedPath else { return .factory }
        let path = URL(fileURLWithPath: assignedPath).standardizedFileURL.path
        if path.hasPrefix("/System/Library/ColorSync/") { return .system }
        if factoryPaths.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == path }) {
            return .factory
        }
        // macOS keeps the generated display factory profiles in the shared Displays folder;
        // assigning another display's factory profile is not a custom profile. The user's own
        // ~/Library/ColorSync/Profiles/Displays is not that folder.
        if path.hasPrefix("/Library/ColorSync/Profiles/Displays/") { return .factory }
        return .custom
    }

    /// What the guard knows about one connected display's assignment.
    public enum Knowledge: Hashable, Sendable {
        /// ColorSync reported it, in this read or an earlier one.
        case verified(Assignment)
        /// Connected, and no read has succeeded for it yet: the first read is still pending, or
        /// failed. It might be a custom profile, so it blocks like one.
        case unverified
    }

    /// Folds one round of ColorSync reads into what the guard knows. Every display in `connected`
    /// gets an entry: the assignment just read; otherwise — the read failed, or the display arrived
    /// after the round began — the assignment last verified for it, so a transient ColorSync failure
    /// neither lifts a known block nor invents one; and with nothing verified, `.unverified`.
    /// Displays no longer connected drop out, so one that returns is verified afresh.
    public static func knowledge(connected: Set<DisplayRecordID>, readings: [DisplayRecordID: Assignment],
                                 previous: [DisplayRecordID: Knowledge]) -> [DisplayRecordID: Knowledge] {
        var result: [DisplayRecordID: Knowledge] = [:]
        for id in connected {
            if let reading = readings[id] {
                result[id] = .verified(reading)
            } else if case .verified(let known)? = previous[id] {
                result[id] = .verified(known)
            } else {
                result[id] = .unverified
            }
        }
        return result
    }

    /// A missing entry is pending the first read, just like `.unverified`. The override is
    /// explicit, but one display's custom/unknown assignment must never block another display.
    public static func blocksGamma(for id: DisplayRecordID, knowledge: [DisplayRecordID: Knowledge],
                                   allowGammaWithCustomProfiles: Bool) -> Bool {
        guard !allowGammaWithCustomProfiles else { return false }
        switch knowledge[id] ?? .unverified {
        case .verified(.factory), .verified(.system): return false
        case .verified(.custom), .unverified: return true
        }
    }

    /// The connected displays that keep the guard engaged: a custom profile, or an assignment that
    /// has never been verified.
    public static func blockingDisplays(_ knowledge: [DisplayRecordID: Knowledge]) -> Set<DisplayRecordID> {
        Set(knowledge.filter { $0.value == .verified(.custom) || $0.value == .unverified }.keys)
    }

    /// The blocking displays whose assignment was never read (rather than read as custom), for the
    /// message saying why gamma is paused.
    public static func unverifiedDisplays(_ knowledge: [DisplayRecordID: Knowledge]) -> Set<DisplayRecordID> {
        Set(knowledge.filter { $0.value == .unverified }.keys)
    }
}

/// Successful gamma writes owned by this process. Keep the Core Graphics number with the stable
/// record: after a hot-plug, neither a returning record nor a reused number authorizes a reset.
/// No persisted ownership: safe startup must not reset another app's tables from a prior session.
public struct GammaWriteTracker: Sendable {
    private var written: [DisplayRecordID: UInt32] = [:]

    public init() {}

    public func contains(_ id: DisplayRecordID) -> Bool { written[id] != nil }

    /// A failed first write owns nothing; a failed update doesn't relinquish the earlier table.
    public mutating func recordWrite(for id: DisplayRecordID, displayID: UInt32, succeeded: Bool) {
        if succeeded { written[id] = displayID }
    }

    /// Restore selection is deliberately per display, never "all displays". A missing/different
    /// current number means the original surface is gone, so it must receive no transfer call.
    public func displayToRestore(for id: DisplayRecordID, currentDisplayID: UInt32?) -> UInt32? {
        guard let original = written[id], original == currentDisplayID else { return nil }
        return original
    }

    /// Keep ownership after a rejected identity transfer so a later explicit cleanup can try again.
    public mutating func recordRestore(for id: DisplayRecordID, succeeded: Bool) {
        if succeeded { written[id] = nil }
    }

    public mutating func retainConnected(_ connected: [DisplayRecordID: UInt32]) {
        written = written.filter { connected[$0.key] == $0.value }
    }
}
