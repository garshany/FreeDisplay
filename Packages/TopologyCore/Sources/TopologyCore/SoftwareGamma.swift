import DisplayDomain
import Foundation

/// Who holds a display's gamma (colour-table) slot and what the next software-image write must do
/// with it. Pure, so the "overlay never touches gamma" and "blocked gamma hands the slot back"
/// rules are unit-tested; the app performs the Core Graphics calls.
///
/// A "neutral" formula is not a bypass: writing an identity transfer still replaces the table the
/// display's ColorSync profile installed. So when nothing needs gamma, OpenDisplay makes no
/// colour-table call at all — or, if its own table is still there, hands the slot back to ColorSync.
public enum GammaSlotPolicy {
    public enum Action: Hashable, Sendable {
        /// Express the composed dim × warmth × contrast × boost transfer (`SoftwareImageTransfer`).
        case write
        /// Restore ColorSync's table: OpenDisplay's is installed but nothing may (or needs to) use it.
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

/// The default custom-profile safeguard: a user or shared custom ICC profile assigned to ANY
/// connected display blocks OpenDisplay's gamma writes on EVERY display, because colour-table
/// writes combined with such profiles can leave a screen black or tinted while it is still
/// connected. Factory and system profiles don't trigger it. The app can override it explicitly.
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

    /// The connected displays that keep the guard engaged. `readings` holds the displays whose
    /// assignment could be read; a display in `unreadable` keeps whatever it was before — a
    /// transient ColorSync failure must not lift a known block. Displays no longer connected (in
    /// neither set) drop out.
    public static func blockingDisplays(readings: [DisplayRecordID: Assignment],
                                        unreadable: Set<DisplayRecordID>,
                                        previous: Set<DisplayRecordID>) -> Set<DisplayRecordID> {
        Set(readings.filter { $0.value == .custom }.keys).union(unreadable.intersection(previous))
    }
}
