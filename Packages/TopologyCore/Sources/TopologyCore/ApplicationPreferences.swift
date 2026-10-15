import Foundation
import DisplayDomain

// Application timing, motion and Settings-window preferences (SO-10/SD-08). Pure value types and
// the decisions made from them; the app reads the clock, the screens and macOS's Reduce Motion
// switch and passes them in.

// MARK: - Timing values

/// One optional timing preference. A blank field is `automatic` — the app's own behaviour, which
/// is not the same as zero: zero says "no delay / no animation" explicitly and stays that way if
/// the automatic behaviour ever changes.
public enum TimingValue: Hashable, Sendable {
    /// The field is blank: use the app's own behaviour.
    case automatic
    /// An explicit number of seconds the user typed (zero included).
    case seconds(Double)

    /// The value the field shows: blank for automatic.
    public var fieldText: String {
        guard case .seconds(let seconds) = self else { return "" }
        // Whole numbers without a trailing ".0"; anything else keeps every digit typed ("1.25").
        if let whole = Int64(exactly: seconds) { return String(whole) }
        return String(seconds)
    }

    /// Whether the value can be used where it is applied: a finite, non-negative number of seconds
    /// whose nanoseconds fit the `UInt64` that `Task.sleep` takes. Technical validity only — no
    /// product range is implied (the caller may supply a maximum).
    public var isUsable: Bool {
        guard case .seconds(let seconds) = self else { return true }
        return TimingValue.isSchedulable(seconds)
    }

    static func isSchedulable(_ seconds: Double) -> Bool {
        // 2^64 itself is not representable as UInt64, so the bound is strict.
        seconds.isFinite && seconds >= 0 && seconds * 1_000_000_000 < 18_446_744_073_709_551_616.0
    }
}

extension TimingValue: Codable {
    /// `null` is automatic and a number is seconds, so a settings file stays readable by hand. A
    /// number is kept as written even when it can't be used, so an import can name and refuse it
    /// (`OpenDisplaySettings.unusableValueKey`); wherever it is applied, an unusable value counts
    /// as automatic (`ApplicationTiming.seconds`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .automatic
            return
        }
        self = .seconds(try container.decode(Double.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .automatic: try container.encodeNil()
        case .seconds(let seconds): try container.encode(seconds)
        }
    }
}

/// Why a typed timing value was not accepted. The field keeps the previous value in every case.
public enum TimingRejection: Hashable, Sendable {
    /// Not a number (letters, "nan", "inf", …).
    case notANumber
    /// Below zero: a delay or a duration can't be negative.
    case negative
    /// So large that its nanoseconds don't fit what the scheduler takes.
    case tooLargeToSchedule
    /// Above a maximum the caller configured. No maximum exists unless one is passed in.
    case aboveMaximum(Double)
}

/// What a timing field made of its text.
public enum TimingFieldInput: Hashable, Sendable {
    case accepted(TimingValue)
    case rejected(TimingRejection)
}

/// The three application timings: how long to wait after a display configuration change and after
/// waking before the app applies what the user set up, and how long menu transitions take.
public struct ApplicationTimingPreferences: Hashable, Sendable {
    /// Wait this long after macOS reports a display configuration change before applying the
    /// user's automatic rules (turning the built-in off, keeping turned-off displays off, restoring
    /// a protected layout). The safety net that keeps a screen lit never waits for it.
    public var configurationDelay: TimingValue
    /// Wait this long after the Mac wakes before applying those rules.
    public var wakeDelay: TimingValue
    /// How long the menu's open/close transitions take. Zero turns transitions off; macOS Reduce
    /// Motion and the menu's own "Animate the menu" switch turn them off whatever this says.
    public var animationDuration: TimingValue

    public init(configurationDelay: TimingValue = .automatic,
                wakeDelay: TimingValue = .automatic,
                animationDuration: TimingValue = .automatic) {
        self.configurationDelay = configurationDelay
        self.wakeDelay = wakeDelay
        self.animationDuration = animationDuration
    }

    public static let `default` = ApplicationTimingPreferences()

    /// The first field holding a value that can't be used, by its key — for import validation.
    public var unusableFieldKey: String? {
        if !configurationDelay.isUsable { return "configurationDelay" }
        if !wakeDelay.isUsable { return "wakeDelay" }
        if !animationDuration.isUsable { return "animationDuration" }
        return nil
    }
}

extension ApplicationTimingPreferences: Codable {
    private enum CodingKeys: String, CodingKey { case configurationDelay, wakeDelay, animationDuration }

    /// Per-field tolerant, like `OpenDisplaySettings`: one unusable value costs that value only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field(_ key: CodingKeys) -> TimingValue {
            (try? container.decodeIfPresent(TimingValue.self, forKey: key)) ?? .automatic
        }
        configurationDelay = field(.configurationDelay)
        wakeDelay = field(.wakeDelay)
        animationDuration = field(.animationDuration)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configurationDelay, forKey: .configurationDelay)
        try container.encode(wakeDelay, forKey: .wakeDelay)
        try container.encode(animationDuration, forKey: .animationDuration)
    }
}

/// Reading and applying timing preferences.
public enum ApplicationTiming {
    /// What "automatic" means for the two delays: no added wait. That is how the app has always
    /// reacted (every rule runs as soon as the change is seen, and each one re-checks as displays
    /// keep settling), so leaving the fields blank changes nothing.
    public static let automaticConfigurationDelay: TimeInterval = 0
    public static let automaticWakeDelay: TimeInterval = 0

    /// Reads a timing field. Blank (or only spaces) is `automatic`; a comma works as the decimal
    /// separator too. `maximum` is a ceiling the caller may impose; there is none by default.
    public static func parse(_ text: String, maximum: Double? = nil) -> TimingFieldInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .accepted(.automatic) }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(normalized), seconds.isFinite,
              normalized.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" || $0 == "e" || $0 == "E" })
        else { return .rejected(.notANumber) }
        if seconds < 0 { return .rejected(.negative) }
        if let maximum, seconds > maximum { return .rejected(.aboveMaximum(maximum)) }
        guard TimingValue.isSchedulable(seconds) else { return .rejected(.tooLargeToSchedule) }
        // "-0" is zero, not a negative delay.
        return .accepted(.seconds(seconds == 0 ? 0 : seconds))
    }

    /// The seconds to use for `value`: `automatic` when blank or (defensively) unusable.
    public static func seconds(_ value: TimingValue, automatic: TimeInterval) -> TimeInterval {
        guard case .seconds(let seconds) = value, TimingValue.isSchedulable(seconds) else { return automatic }
        return seconds
    }

    /// The duration a transition should take, or nil for no animation at all: Reduce Motion, the
    /// "Animate the menu" switch turned off, and an explicit zero each mean no transition.
    public static func transitionDuration(_ value: TimingValue, automatic: TimeInterval,
                                          animationsEnabled: Bool, reduceMotion: Bool) -> TimeInterval? {
        guard animationsEnabled, !reduceMotion else { return nil }
        let duration = seconds(value, automatic: automatic)
        return duration > 0 ? duration : nil
    }
}

// MARK: - When configured reactions run

/// When the app applies the user's automatic rules after a display event, given the two delays.
/// One shared schedule for every rule, so the wait is one debounce rather than a sleep in each
/// service: every new event re-arms the same timer, and the rules run once things are quiet.
public enum ConfiguredReactionSchedule {
    public enum Trigger: Hashable, Sendable {
        /// macOS reported a display configuration change.
        case topologyChange
        /// The Mac woke from sleep.
        case wake
    }

    /// Seconds to wait from `now` before the rules run for an event of `trigger`. Zero means run
    /// now. A configuration change inside the wake delay waits for whichever ends later, so the
    /// displays settling after a wake can't cut the wake delay short.
    public static func delay(for trigger: Trigger, now: Date, lastWakeAt: Date?,
                             timing: ApplicationTimingPreferences) -> TimeInterval {
        let configuration = ApplicationTiming.seconds(timing.configurationDelay,
                                                      automatic: ApplicationTiming.automaticConfigurationDelay)
        let wake = ApplicationTiming.seconds(timing.wakeDelay, automatic: ApplicationTiming.automaticWakeDelay)
        switch trigger {
        case .wake:
            return wake
        case .topologyChange:
            guard let lastWakeAt else { return configuration }
            let wakeRemaining = lastWakeAt.addingTimeInterval(wake).timeIntervalSince(now)
            return max(configuration, wakeRemaining, 0)
        }
    }

    /// The trigger a coalesced run reports: a wake still waiting outranks the configuration changes
    /// that follow it, because the rules treat a wake differently (Protected Layout's wake window).
    public static func merged(_ pending: Trigger?, with new: Trigger) -> Trigger {
        pending == .wake ? .wake : new
    }
}

// MARK: - Settings window placement

/// Where the Settings window opens (SD-08).
public enum SettingsWindowPlacement: String, Hashable, Sendable, Codable, CaseIterable {
    /// Where it was last left, when that spot is still on a connected screen.
    case lastPosition
    /// Centred on the screen under the pointer, every time.
    case pointerScreen
}

/// A window or screen rectangle in AppKit's global coordinates (points, bottom-left origin).
public struct WindowFrame: Hashable, Sendable {
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

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// The overlapping area with `other`, zero when they don't overlap.
    public func intersectionArea(with other: WindowFrame) -> Double {
        let w = min(maxX, other.maxX) - max(x, other.x)
        let h = min(maxY, other.maxY) - max(y, other.y)
        return w > 0 && h > 0 ? w * h : 0
    }
}

public enum SettingsWindowPlacementPolicy {
    /// The origin for a window of `size` (width, height). `screens` are the visible frames of the
    /// connected screens; `pointerScreen` is the visible frame of the screen under the pointer.
    ///
    /// `lastPosition` reuses `saved` when it still overlaps a connected screen at all, moved just
    /// enough to fit inside the screen it overlaps most — so a window left on a display that is now
    /// smaller, rearranged or gone never opens out of reach. Otherwise, and for `pointerScreen`, the
    /// window is centred on the pointer's screen (or the first screen). Nil when there are no
    /// screens, which leaves the window where AppKit put it.
    public static func origin(placement: SettingsWindowPlacement, saved: WindowFrame?,
                              width: Double, height: Double,
                              screens: [WindowFrame], pointerScreen: WindowFrame?) -> (x: Double, y: Double)? {
        let frame = saved.map { WindowFrame(x: $0.x, y: $0.y, width: width, height: height) }
        guard let screen = destinationScreen(placement: placement, saved: frame,
                                             screens: screens, pointerScreen: pointerScreen) else { return nil }
        if placement == .lastPosition, let frame, frame.intersectionArea(with: screen) > 0 {
            return clamp(frame, into: screen)
        }
        let centred = WindowFrame(x: screen.x + (screen.width - width) / 2,
                                  y: screen.y + (screen.height - height) / 2, width: width, height: height)
        return clamp(centred, into: screen)
    }

    /// The destination also determines the restored size, so a pointer on a smaller screen does
    /// not shrink a window whose remembered position is on a connected larger screen.
    public static func destinationScreen(placement: SettingsWindowPlacement, saved: WindowFrame?,
                                         screens: [WindowFrame], pointerScreen: WindowFrame?) -> WindowFrame? {
        if placement == .lastPosition, let saved {
            let best = screens.map { (screen: $0, area: saved.intersectionArea(with: $0)) }
                .filter { $0.area > 0 }.max { $0.area < $1.area }
            if let best { return best.screen }
        }
        return pointerScreen ?? screens.first
    }

    /// Moves `frame` inside `screen`. When the window is larger than the screen it is pinned to the
    /// left and top edges: the title bar, which is how a window is moved, stays reachable.
    private static func clamp(_ frame: WindowFrame, into screen: WindowFrame) -> (x: Double, y: Double) {
        let x = frame.width >= screen.width ? screen.x : min(max(frame.x, screen.x), screen.maxX - frame.width)
        let y = frame.height >= screen.height
            ? screen.maxY - frame.height
            : min(max(frame.y, screen.y), screen.maxY - frame.height)
        return (x, y)
    }
}

/// Cancelling a timer cannot retract async work it already handed off. Every rearm or lifecycle
/// cancellation invalidates that run's token; hosts check again after awaits and before mutations.
public struct ConfiguredReactionGeneration: Sendable {
    private var current = UUID()
    private var authorization = WriteAuthorization()
    public init() {}
    @discardableResult
    public mutating func invalidate() -> UUID {
        authorization.revoke()
        authorization = WriteAuthorization()
        current = UUID()
        return current
    }
    public func isCurrent(_ token: UUID) -> Bool { current == token }
    public func admission(for token: UUID) -> WriteAuthorization {
        if isCurrent(token) { return authorization }
        let refused = WriteAuthorization()
        refused.revoke()
        return refused
    }
}
