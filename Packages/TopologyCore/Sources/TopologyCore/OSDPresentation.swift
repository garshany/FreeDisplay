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

/// Where the HUD appears on the target display.
public enum OSDPosition: String, Hashable, Sendable, Codable, CaseIterable {
    case bottomCenter
    case topCenter
    case center
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
        Route(drawsLocalHUD: localHUDWanted && settings.osdEnabled && settings.osdStyle != .external,
              publishesEvent: settings.publishOSDEventsEnabled)
    }

    /// True when the feedback settings promise a presentation that nothing delivers (SO-04):
    /// "External HUD only" suppresses OpenDisplay's HUD so an external app can draw instead, but
    /// with broadcasting off no external app receives anything — key presses get no feedback at all.
    public static func externalOnlyDeliversNothing(_ settings: OpenDisplaySettings) -> Bool {
        settings.osdEnabled && settings.osdStyle == .external && !settings.publishOSDEventsEnabled
    }
}
