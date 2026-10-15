import AutomationSchema
import DisplayDomain
import Foundation

// App-drawn OSD placement, values and interaction (SO-35, TR-17) and the delivery state Settings
// reports (SO-04/IN-16). Pure decisions; the macOS layer measures screens and the pointer, draws the
// panel and asks these what to do.

// MARK: - Settings

/// Which screen OpenDisplay's own HUD appears on, chosen independently of which display was
/// adjusted (SO-35, T26). Under the menu-bar icon ignores it: that placement goes where the icon is.
public enum OSDScreenChoice: String, Hashable, Sendable, Codable, CaseIterable {
    /// The display whose brightness or sound changed (the default, and the behaviour before this
    /// choice existed).
    case affectedDisplay
    /// The screen under the mouse pointer.
    case pointer
    /// The screen with the focused window — AppKit's "main screen", which follows keyboard focus.
    case focused
    /// The macOS primary display, the one at the origin of the desktop arrangement
    /// (`CGMainDisplayID`). Not the focused screen, even though AppKit also calls that one "main".
    case primary
}

/// The OSD preferences added after the original four (`osdEnabled`, `osdStyle`, `osdPosition`,
/// `publishOSDEventsEnabled`), kept together so they travel as one value. Every field decodes on its
/// own: a missing or unreadable one takes its default and leaves the rest alone.
public struct OSDFeedbackSettings: Hashable, Sendable, Codable {
    /// Feedback for changes other than brightness, volume and mute — today the input switch. Its
    /// own switch, independent of `osdEnabled` (the basic feedback switch).
    public var showsCustomFeedback: Bool
    /// Displays (by `DisplayRecordID.rawValue`) whose volume and mute changes show no local HUD.
    /// The change still happens and is still published.
    public var volumeHiddenDisplayIDs: Set<String>
    /// The screen the HUD appears on.
    public var screen: OSDScreenChoice
    /// Show the level as a number beside the bar.
    public var showsValue: Bool
    /// Draw the level as 16 segments, as macOS does; off draws one continuous bar.
    public var segmentedBar: Bool
    public var rounded: Bool
    public var adaptiveBackground: Bool
    public var shadow: Bool
    /// The HUD takes the pointer: hovering keeps it up, dragging its bar continues the adjustment.
    /// Off keeps it click-through, so it can never catch a click meant for the window beneath.
    public var interactive: Bool
    /// Optional sound when an interactive volume adjustment finishes, never during a drag.
    public var volumeCompletionSound: Bool
    /// Answer receiver apps' requests to read and take over the feedback settings
    /// (`OSDSettingsHandshake`). Off by default: until the user allows it, no other process can
    /// change what OpenDisplay shows.
    public var receiverHandshakeEnabled: Bool
    /// The receiver app that currently has the feedback settings, with what to give back.
    public var receiverClaim: OSDReceiverClaim?

    public init(showsCustomFeedback: Bool = true, volumeHiddenDisplayIDs: Set<String> = [],
                screen: OSDScreenChoice = .affectedDisplay, showsValue: Bool = true,
                segmentedBar: Bool = true, interactive: Bool = false,
                receiverHandshakeEnabled: Bool = false, receiverClaim: OSDReceiverClaim? = nil,
                volumeCompletionSound: Bool = false, rounded: Bool = false,
                adaptiveBackground: Bool = true, shadow: Bool = true) {
        self.showsCustomFeedback = showsCustomFeedback
        self.volumeHiddenDisplayIDs = volumeHiddenDisplayIDs
        self.screen = screen
        self.showsValue = showsValue
        self.segmentedBar = segmentedBar
        self.rounded = rounded
        self.adaptiveBackground = adaptiveBackground
        self.shadow = shadow
        self.interactive = interactive
        self.volumeCompletionSound = volumeCompletionSound
        self.receiverHandshakeEnabled = receiverHandshakeEnabled
        self.receiverClaim = receiverClaim
    }

    public static let `default` = OSDFeedbackSettings()

    private enum CodingKeys: String, CodingKey {
        case showsCustomFeedback, volumeHiddenDisplayIDs, screen, showsValue, segmentedBar, interactive
        case receiverHandshakeEnabled, receiverClaim
        case volumeCompletionSound
        case rounded, adaptiveBackground, shadow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        showsCustomFeedback = value(Bool.self, .showsCustomFeedback) ?? defaults.showsCustomFeedback
        volumeHiddenDisplayIDs = value(Set<String>.self, .volumeHiddenDisplayIDs) ?? defaults.volumeHiddenDisplayIDs
        screen = value(OSDScreenChoice.self, .screen) ?? defaults.screen
        showsValue = value(Bool.self, .showsValue) ?? defaults.showsValue
        segmentedBar = value(Bool.self, .segmentedBar) ?? defaults.segmentedBar
        rounded = value(Bool.self, .rounded) ?? defaults.rounded
        adaptiveBackground = value(Bool.self, .adaptiveBackground) ?? defaults.adaptiveBackground
        shadow = value(Bool.self, .shadow) ?? defaults.shadow
        interactive = value(Bool.self, .interactive) ?? defaults.interactive
        volumeCompletionSound = value(Bool.self, .volumeCompletionSound) ?? defaults.volumeCompletionSound
        receiverHandshakeEnabled = value(Bool.self, .receiverHandshakeEnabled) ?? defaults.receiverHandshakeEnabled
        receiverClaim = value(OSDReceiverClaim.self, .receiverClaim)
    }
}

// MARK: - Delivery state (what Settings says)

extension OSDFeedbackPolicy {
    /// Where feedback goes under the current settings — one answer for Settings to state, so
    /// "External HUD only" always says whether anything is being dispatched and two renderers are
    /// never on without a word about duplicates (SO-35, T30).
    public enum Delivery: Hashable, Sendable {
        /// Only OpenDisplay's HUD.
        case localOnly
        /// OpenDisplay's HUD and the published events. An app drawing from the events shows the same
        /// change a second time unless its own HUD, or this one, is off.
        case localAndPublished
        /// "External HUD only" with publishing on: another app is expected to draw.
        case externalOnly
        /// "External HUD only" with publishing off: nothing is shown anywhere.
        case externalOnlyWithoutDispatch
        /// No local HUD (switched off), events published.
        case publishedOnly
        /// No local HUD and nothing published.
        case none
    }

    public static func delivery(_ settings: OpenDisplaySettings) -> Delivery {
        let publishing = settings.publishOSDEventsEnabled
        if settings.osdStyle == .external {
            return publishing ? .externalOnly : .externalOnlyWithoutDispatch
        }
        let drawsLocally = settings.osdStyle != .external
            && (settings.osdEnabled || settings.osdFeedback.showsCustomFeedback)
        switch (drawsLocally, publishing) {
        case (true, true): return .localAndPublished
        case (true, false): return .localOnly
        case (false, true): return .publishedOnly
        case (false, false): return .none
        }
    }
}

// MARK: - Screen

/// Picks the screen the HUD appears on (SO-35, TR-17). Display numbers are Core Graphics display IDs.
public enum OSDScreenPolicy {
    /// - Parameters:
    ///   - position: under the menu-bar icon goes to the icon's screen when there is one.
    ///   - affected/pointer/focused/primary: the candidate for each choice, nil when unknown.
    ///   - iconScreen: the screen showing OpenDisplay's menu-bar icon, nil when macOS hides it.
    ///   - available: the screens a window can appear on now.
    /// - Returns: the chosen screen when it is available; otherwise the primary display; otherwise
    ///   the first available screen. Never a guess for a choice the user didn't make: an absent
    ///   affected display falls back to the primary, not to wherever the pointer happens to be.
    public static func screen(position: OSDPosition, choice: OSDScreenChoice,
                              affected: UInt32?, pointer: UInt32?, focused: UInt32?, primary: UInt32?,
                              iconScreen: UInt32?, available: [UInt32]) -> UInt32? {
        func usable(_ id: UInt32?) -> UInt32? { id.flatMap { available.contains($0) ? $0 : nil } }
        if (position == .underMenuBarIcon || position == .underMenuBar), let icon = usable(iconScreen) { return icon }
        let chosen: UInt32?
        switch choice {
        case .affectedDisplay: chosen = affected
        case .pointer: chosen = pointer
        case .focused: chosen = focused
        case .primary: chosen = primary
        }
        return usable(chosen) ?? usable(primary) ?? available.first
    }
}

// MARK: - Layout

/// A rectangle in AppKit's global screen space: points, bottom-left origin, y grows upward.
public struct OSDFrame: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// Where the HUD's window goes on its screen (SO-35).
public enum OSDLayout {
    /// The bottom placement's distance above the Dock/visible bottom edge — where macOS's own HUD sat.
    public static let bottomOffset = 140.0
    /// The top-centre placement's distance below the menu bar.
    public static let topOffset = 60.0
    /// The gap kept to a screen edge by the corner placement and the under-icon one.
    public static let edgeInset = 16.0
    /// The gap between the menu bar and an under-icon HUD.
    public static let menuBarGap = 8.0

    /// - Parameters:
    ///   - visibleFrame: the screen's visible frame (menu bar and Dock excluded).
    ///   - icon: the menu-bar icon's frame when it is on this screen; nil otherwise.
    ///   - rightToLeft: the interface's layout direction, for the trailing corner.
    /// - Returns: the window's origin (bottom-left corner).
    public static func origin(position: OSDPosition, width: Double, height: Double,
                              visibleFrame frame: OSDFrame, icon: OSDFrame?,
                              rightToLeft: Bool) -> (x: Double, y: Double) {
        let centredX = frame.midX - width / 2
        switch position {
        case .bottomCenter:
            return (centredX, frame.minY + bottomOffset)
        case .topCenter:
            return (centredX, frame.maxY - height - topOffset)
        case .center:
            return (centredX, frame.midY - height / 2)
        case .topTrailing:
            return trailingCorner(width: width, height: height, frame: frame, rightToLeft: rightToLeft)
        case .underMenuBar:
            let x = icon == nil ? centredX
                : rightToLeft ? frame.minX + edgeInset : frame.maxX - width - edgeInset
            return (x, frame.maxY - height - menuBarGap)
        case .underMenuBarIcon:
            guard let icon, icon.midX >= frame.minX, icon.midX <= frame.maxX else {
                return trailingCorner(width: width, height: height, frame: frame, rightToLeft: rightToLeft)
            }
            // Centred under the icon, but kept fully on the screen: an icon near the edge would
            // otherwise push half the HUD off it.
            let lowest = frame.minX + edgeInset
            let highest = frame.maxX - width - edgeInset
            let x = highest < lowest ? centredX : min(max(icon.midX - width / 2, lowest), highest)
            return (x, min(icon.minY, frame.maxY) - height - menuBarGap)
        }
    }

    private static func trailingCorner(width: Double, height: Double, frame: OSDFrame,
                                       rightToLeft: Bool) -> (x: Double, y: Double) {
        let x = rightToLeft ? frame.minX + edgeInset : frame.maxX - width - edgeInset
        return (x, frame.maxY - height - edgeInset)
    }
}

// MARK: - Interaction

/// When the HUD hides (SO-35). Every appearance gets a new generation, so a fade that finishes
/// after a newer HUD appeared can tell it is stale and leave the newer one up. Hover only holds the
/// HUD once the pointer has moved: a pointer resting where a new HUD happens to appear doesn't keep
/// it, so feedback never gets stuck on screen because the mouse was left there. A drag holds it
/// for as long as it lasts.
public struct OSDHoldTracker: Sendable {
    public enum Decision: Hashable, Sendable {
        /// Hide at this time, unless something newer decides otherwise.
        case hide(at: Date)
        /// Stay up until the pointer leaves or the drag ends.
        case hold
    }

    public private(set) var generation = 0
    public private(set) var hovered = false
    public private(set) var dragging = false
    /// How long the HUD stays after the last change or interaction.
    public var autoHide: TimeInterval
    private var pointerAtAppearance: (x: Double, y: Double)?

    public init(autoHide: TimeInterval) {
        self.autoHide = autoHide
    }

    /// A HUD appeared or its content changed. `pointer` is where the mouse was at that moment.
    public mutating func shown(now: Date, pointer: (x: Double, y: Double)?) -> Decision {
        generation += 1
        // A pointer that was already over an earlier showing keeps its hover; only one that hasn't
        // moved since this showing is treated as resting.
        if !hovered { pointerAtAppearance = pointer }
        return current(now: now)
    }

    /// The pointer moved to `location`, over the HUD or not.
    public mutating func pointerMoved(to location: (x: Double, y: Double), inside: Bool, now: Date) -> Decision {
        generation += 1
        if inside {
            if let resting = pointerAtAppearance, resting == location { return current(now: now) }
            pointerAtAppearance = nil
            hovered = true
        } else {
            hovered = false
        }
        return current(now: now)
    }

    public mutating func pointerExited(now: Date) -> Decision {
        generation += 1
        hovered = false
        return current(now: now)
    }

    public mutating func dragBegan() -> Decision {
        generation += 1
        dragging = true
        pointerAtAppearance = nil
        return .hold
    }

    public mutating func dragEnded(pointerInside: Bool, now: Date) -> Decision {
        generation += 1
        dragging = false
        hovered = pointerInside
        return current(now: now)
    }

    /// The HUD went away; the next showing starts fresh.
    public mutating func hidden() {
        generation += 1
        hovered = false
        dragging = false
        pointerAtAppearance = nil
    }

    /// Whether a fade or timer started for `generation` still belongs to what is on screen.
    public func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    private func current(now: Date) -> Decision {
        hovered || dragging ? .hold : .hide(at: now.addingTimeInterval(autoHide))
    }
}

/// The interactive bar's arithmetic (SO-35).
public enum OSDSliderPolicy {
    public static func playsSound(kind: OSDContent.Kind, completed: Bool, enabled: Bool) -> Bool {
        enabled && completed && kind == .volume
    }
    /// The level a drag at `x` asks for, on a bar starting at `trackMinX` and `trackWidth` long,
    /// clamped to 0...1. Nil for a bar with no width.
    public static func level(atX x: Double, trackMinX: Double, trackWidth: Double) -> Float? {
        guard trackWidth > 0, x.isFinite else { return nil }
        return Float(min(1, max(0, (x - trackMinX) / trackWidth)))
    }

    /// The level after one press of an end icon: `step` towards that end, clamped to 0...1.
    public static func stepped(_ level: Float, by step: Float, up: Bool) -> Float {
        min(1, max(0, level + (up ? step : -step)))
    }

    /// Whether a HUD of this kind offers the bar for dragging: levels do; a mute result and an
    /// input name are results only.
    public static func isAdjustable(_ kind: OSDContent.Kind) -> Bool {
        kind == .brightness || kind == .volume
    }
}

// MARK: - Truthful values (TR-17)

/// What a hardware read-back means for a HUD still showing the change (TR-17).
public enum OSDAssurancePolicy {
    /// A late DDC result cannot verify a newer request or a software adjustment.
    public static func matches(requestedTarget: Int?, completedTarget: Int,
                               assurance: OSDContent.Assurance) -> Bool {
        requestedTarget == completedTarget && assurance == .requested
    }
    /// - Parameter maxValue: the panel's maximum, to turn a reported value into a level.
    /// - Returns: the content as it should now read: verified, or not confirmed with the level the
    ///   panel actually reported when it reported one.
    public static func content(_ content: OSDContent, after verification: DDCWriteVerification,
                               maxValue: Int?) -> OSDContent {
        var updated = content
        switch verification {
        case .applied:
            updated.assurance = .verified
        case .ignored(let actual):
            updated.assurance = .notConfirmed
            if let maxValue, maxValue > 0 { updated.value = max(0, min(1, Float(actual) / Float(maxValue))) }
        case .unknown:
            updated.assurance = .notConfirmed
        }
        return updated
    }
}
