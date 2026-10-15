import DisplayDomain
import Foundation

/// Visual style for the OSD HUD (Batch-3 #5 exposes this; the renderer reads it). Every local style
/// is drawn by OpenDisplay itself; none of them is the macOS system OSD.
public enum OSDStyle: String, Hashable, Sendable, Codable, CaseIterable {
    /// Segmented HUD in the macOS look, app-drawn (default). The raw value predates the label
    /// "Standard" and stays for settings compatibility — it is not the system OSD.
    case native
    /// Compact pill with glyph + bar.
    case minimal
    /// Pre-Tahoe classic HUD look.
    case classicTahoe
    /// Don't draw OpenDisplay's own HUD — only broadcast events (Batch-3 #6) for an external/notch HUD.
    case external
}

/// Where the HUD appears. The centred placements and the top corner are on the screen chosen by
/// `OSDScreenChoice`; under the menu-bar icon is wherever the icon is.
public enum OSDPosition: String, Hashable, Sendable, Codable, CaseIterable {
    case bottomCenter
    case topCenter
    case center
    /// Under OpenDisplay's menu-bar icon, on the icon's screen (SO-35). Where macOS isn't showing
    /// the icon, the top trailing corner of the chosen screen stands in.
    case underMenuBarIcon
    case underMenuBar
    /// The top corner on the reading direction's trailing side: right for left-to-right languages,
    /// left for right-to-left ones.
    case topTrailing

    /// Placements by the menu bar, where an open OpenDisplay menu sits: while it is open they give
    /// way to it (the change itself still happens). The centred placements stay distinct from the
    /// menu and are never suppressed.
    public var isMenuBarAnchored: Bool {
        self == .underMenuBarIcon || self == .underMenuBar || self == .topTrailing
    }
}

/// Decides when to show / refresh / hide the OSD HUD (Batch-3 #2). Pure timing logic (exercised by
/// `make test`); the macOS layer owns the actual window + timer. Rapid changes coalesce: each event
/// pushes the auto-hide deadline forward, so a key-repeat or a slider drag is one continuously-visible
/// HUD rather than a flicker stack.
public struct OSDPresentationPolicy: Sendable {
    /// Seconds the HUD stays up after the last change.
    public var autoHide: TimeInterval
    /// When true, an event identical to what's already shown is ignored rather than re-shown.
    public var suppressUnchanged: Bool

    public init(autoHide: TimeInterval = 1.2, suppressUnchanged: Bool = false) {
        self.autoHide = max(0, autoHide)
        self.suppressUnchanged = suppressUnchanged
    }

    public enum Decision: Hashable, Sendable {
        /// Show (or update) the HUD with `content`, scheduling it to hide at `hideAt`.
        case show(OSDContent, hideAt: Date)
        /// Do nothing (a suppressed no-op).
        case ignore
    }

    /// Decide what to do for a new `event` given the currently-shown `previous` content.
    public func decide(event: OSDContent, previous: OSDContent?, now: Date) -> Decision {
        if suppressUnchanged, let previous, previous == event { return .ignore }
        return .show(event, hideAt: now.addingTimeInterval(autoHide))
    }

    /// Whether a HUD scheduled to hide at `hideAt` should now be hidden.
    public func shouldHide(now: Date, hideAt: Date) -> Bool {
        now >= hideAt
    }
}

/// Who hears about one brightness/volume change. The local HUD and the external event are two
/// independent audiences (IN-04): the HUD is a confirmation for gestures that show no value of their
/// own (keys), while the event is the published record of every change for `listen` and notch/HUD
/// apps — so a slider, HTTP, CLI or Intent change is published even though it draws no HUD here.
public enum OSDFeedbackPolicy {
    public struct Route: Hashable, Sendable {
        /// Draw OpenDisplay's own HUD.
        public var drawsLocalHUD: Bool
        /// Post the `OSDBroadcast` distributed notification.
        public var publishesEvent: Bool

        public init(drawsLocalHUD: Bool, publishesEvent: Bool) {
            self.drawsLocalHUD = drawsLocalHUD
            self.publishesEvent = publishesEvent
        }
    }

    /// - Parameter localHUDWanted: whether this change's origin asks for a local confirmation at
    ///   all (key presses do; sliders, which already show their value, don't).
    public static func route(localHUDWanted: Bool, settings: OpenDisplaySettings) -> Route {
        route(Context(kind: .brightness, localHUDWanted: localHUDWanted), settings: settings)
    }

    /// One change as the feedback switches see it (SO-35).
    public struct Context: Hashable, Sendable {
        public var kind: OSDContent.Kind
        /// The changed display's stable record id, for the per-display volume switch; nil when the
        /// change has no single display.
        public var displayID: String?
        /// Whether this change's origin asks for a local confirmation at all.
        public var localHUDWanted: Bool
        /// Whether OpenDisplay's menu is open right now.
        public var menuOpen: Bool

        public init(kind: OSDContent.Kind, displayID: String? = nil, localHUDWanted: Bool, menuOpen: Bool = false) {
            self.kind = kind
            self.displayID = displayID
            self.localHUDWanted = localHUDWanted
            self.menuOpen = menuOpen
        }
    }

    /// The basic switch covers brightness, volume and mute; everything else — today the input
    /// switch — is custom feedback with its own switch. The two are independent: either can be on
    /// with the other off.
    public static func isBasic(_ kind: OSDContent.Kind) -> Bool {
        switch kind {
        case .brightness, .volume, .mute: return true
        case .input: return false
        }
    }

    /// Who hears about one change. The event is published whatever happens locally: the per-display
    /// volume switch, an open menu and the feedback switches only decide OpenDisplay's own HUD.
    public static func route(_ context: Context, settings: OpenDisplaySettings) -> Route {
        Route(drawsLocalHUD: drawsLocalHUD(context, settings: settings),
              publishesEvent: settings.publishOSDEventsEnabled)
    }

    /// A display group's follower write (owner decision #8): published as the follower's own event
    /// (`OSDBroadcast.Source.groupSync`) whenever events are, and never drawn — the leader's change
    /// already showed whatever feedback it asked for, and one HUD per follower would stack up.
    public static func groupFollowerRoute(settings: OpenDisplaySettings) -> Route {
        route(Context(kind: .brightness, localHUDWanted: false), settings: settings)
    }

    private static func drawsLocalHUD(_ context: Context, settings: OpenDisplaySettings) -> Bool {
        guard context.localHUDWanted, settings.osdStyle != .external else { return false }
        let switchedOn = isBasic(context.kind) ? settings.osdEnabled : settings.osdFeedback.showsCustomFeedback
        guard switchedOn else { return false }
        // The per-display volume switch covers mute too: both report that display's sound.
        if context.kind == .volume || context.kind == .mute, let id = context.displayID,
           !settings.showsVolumeFeedback(for: DisplayRecordID(rawValue: id)) { return false }
        if context.menuOpen, settings.osdPosition.isMenuBarAnchored { return false }
        return true
    }

    /// True when the feedback settings promise a presentation that nothing delivers (SO-04):
    /// "External HUD only" suppresses OpenDisplay's HUD so an external app can draw instead, but
    /// with broadcasting off no external app receives anything — key presses get no feedback at all.
    public static func externalOnlyDeliversNothing(_ settings: OpenDisplaySettings) -> Bool {
        settings.osdStyle == .external && !settings.publishOSDEventsEnabled
    }
}
