import Foundation

/// How a request wants brightness driven (FD-066, TB-36). `automatic` is what a slider does; the
/// others are explicit choices that are honoured or refused — never quietly replaced. In particular
/// `hardware` ("hardware brightness only") fails rather than dimming pixels in software, which is
/// what a Home Assistant automation driving a monitor's backlight needs.
public enum BrightnessMethodRequest: String, Hashable, Sendable, Codable, CaseIterable {
    /// The display's own route, as its slider uses it: native, else DDC, else software dimming.
    case automatic
    /// A hardware backlight only — native (DisplayServices) or DDC/CI. Never software dimming.
    case hardware
    /// The display's native brightness control (built-in panels, Apple displays) only.
    case native
    /// The monitor's DDC/CI brightness only.
    case ddc
    /// Software dimming (gamma/overlay) only.
    case software

    /// Accepts the canonical names plus `auto`, `hardware-only`/`hardwareOnly`, `gamma`.
    public static func parse(_ text: String, parameter: String = "method") throws(AutomationIssue) -> BrightnessMethodRequest {
        let key = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        switch key {
        case "automatic", "auto": return .automatic
        case "hardware", "hardwareonly": return .hardware
        case "native": return .native
        case "ddc", "ddcci": return .ddc
        case "software", "gamma": return .software
        default:
            throw .invalidValue(parameter, "'\(text)' is not a method (automatic, hardware, native, ddc, software)")
        }
    }
}

/// The concrete way a brightness level reaches a display.
public enum BrightnessRoute: String, Hashable, Sendable, Codable, CaseIterable {
    /// DisplayServices — the system's own brightness (built-in panels, Apple displays).
    case native
    /// DDC/CI — the monitor's backlight over I²C.
    case ddc
    /// Gamma/overlay dimming applied by OpenDisplay.
    case software

    public var isHardware: Bool { self != .software }

    /// The search order for `automatic` and `hardware` when the display has no current route.
    static let preference: [BrightnessRoute] = [.native, .ddc, .software]
}

/// Why a route can't carry a request for one display.
public enum BrightnessRouteUnavailableReason: String, Hashable, Sendable, Codable {
    /// The display has no such control (no native brightness, no DDC answer).
    case notOffered
    /// This build doesn't include the route (the public-API-only build has no DisplayServices/DDC).
    case notInThisBuild
    /// DDC was withheld for safety (ambiguous identity, Apple display without the user's override).
    case refused
    /// The user set this display to software dimming in OpenDisplay.
    case softwarePreferred
    /// Software dimming lives in the process that sets it, so a command-line run that exits would
    /// take it away again.
    case notInThisProcess
    /// The app drives this display through another route and doesn't switch routes for one request.
    case notCurrentRoute
}

/// Which routes one display offers right now, and the one its slider uses.
public struct BrightnessRouteAvailability: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case available
        case unavailable(BrightnessRouteUnavailableReason, detail: String? = nil)
    }

    /// The route the display is driven through now (what `automatic` keeps), or nil when none.
    public var current: BrightnessRoute?
    public var states: [BrightnessRoute: State]

    public init(current: BrightnessRoute?, states: [BrightnessRoute: State]) {
        self.current = current
        self.states = states
    }

    /// A route the availability doesn't mention is not offered.
    public func state(of route: BrightnessRoute) -> State {
        states[route] ?? .unavailable(.notOffered)
    }

    public func isAvailable(_ route: BrightnessRoute) -> Bool { state(of: route) == .available }
}

/// Chooses the route for a request (FD-066). Pure, so "hardware only never falls back to software"
/// is a unit-tested rule rather than a convention each surface has to remember.
public enum BrightnessRoutePolicy {
    public static func choose(_ request: BrightnessMethodRequest, availability: BrightnessRouteAvailability,
                              displayName: String) throws(AutomationIssue) -> BrightnessRoute {
        switch request {
        case .automatic:
            if let current = availability.current, availability.isAvailable(current) { return current }
            if let route = BrightnessRoute.preference.first(where: availability.isAvailable) { return route }
            throw unavailable(request, availability: availability, considered: BrightnessRoute.preference,
                              displayName: displayName)
        case .hardware:
            if let current = availability.current, current.isHardware, availability.isAvailable(current) { return current }
            let hardware = BrightnessRoute.preference.filter(\.isHardware)
            if let route = hardware.first(where: availability.isAvailable) { return route }
            throw unavailable(request, availability: availability, considered: hardware, displayName: displayName)
        case .native, .ddc, .software:
            let route: BrightnessRoute = request == .native ? .native : request == .ddc ? .ddc : .software
            if availability.isAvailable(route) { return route }
            throw unavailable(request, availability: availability, considered: [route], displayName: displayName)
        }
    }

    private static func unavailable(_ request: BrightnessMethodRequest, availability: BrightnessRouteAvailability,
                                    considered: [BrightnessRoute], displayName: String) -> AutomationIssue {
        let reasons = considered.compactMap { route -> String? in
            guard case .unavailable(let reason, let detail) = availability.state(of: route) else { return nil }
            return "\(route.rawValue): \(detail ?? explanation(reason))"
        }
        let what: String
        switch request {
        case .automatic: what = "No brightness control is available for \(displayName)"
        case .hardware: what = "Hardware brightness isn't available for \(displayName); software dimming was not used"
        case .native, .ddc, .software: what = "\(request.rawValue) brightness isn't available for \(displayName)"
        }
        let detail = reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))"
        return AutomationIssue(.methodUnavailable, what + detail, subject: request.rawValue)
    }

    public static func explanation(_ reason: BrightnessRouteUnavailableReason) -> String {
        switch reason {
        case .notOffered: return "the display doesn't offer it"
        case .notInThisBuild: return "not included in this build"
        case .refused: return "withheld for safety"
        case .softwarePreferred: return "the display is set to software dimming in OpenDisplay"
        case .notInThisProcess: return "software dimming would end when the command exits"
        case .notCurrentRoute: return "OpenDisplay drives this display through another route"
        }
    }
}

/// What could be read from a display after (or without) a brightness write.
public enum BrightnessReadback: Hashable, Sendable {
    /// A 0…1 level the display reported (native control).
    case level(Double)
    /// A DDC/CI reading in the monitor's own units.
    case ddc(current: Int, max: Int)
    /// The level OpenDisplay applied with software dimming — known, but not reported by the display.
    case applied(Double)
    /// Nothing could be read.
    case none

    /// The level the readback stands for, when there is one.
    public var level: AutomationLevel? {
        switch self {
        case .level(let value), .applied(let value): return AutomationLevel(normalized: value)
        case .ddc(let current, let max): return AutomationLevel(raw: current, maximum: max)
        case .none: return nil
        }
    }

    /// True when the display itself reported the value (not OpenDisplay's own record of it).
    public var isReportedByDisplay: Bool {
        switch self {
        case .level, .ddc: return true
        case .applied, .none: return false
        }
    }
}

/// What a surface's brightness primitive reports back to the engine.
public struct BrightnessWriteReport: Hashable, Sendable {
    /// The absolute level that was written — for a relative change, where it landed after clamping.
    public var requested: AutomationLevel
    /// Whether the route accepted the write (false: it failed before anything changed).
    public var accepted: Bool
    public var readback: BrightnessReadback
    /// Why the write failed, when it did.
    public var failure: String?

    public init(requested: AutomationLevel, accepted: Bool, readback: BrightnessReadback, failure: String? = nil) {
        self.requested = requested
        self.accepted = accepted
        self.readback = readback
        self.failure = failure
    }
}

/// Judges a brightness write by its read-back — the one settlement rule every surface uses (FD-066).
///
/// - A native read-back must land on the requested whole percent (the unit actions speak).
/// - A DDC read-back is judged in the monitor's units with one unit of rounding, exactly as the
///   app's own DDC write verification judges every slider write (`DDCWriteVerification`).
/// - Software dimming is reported with the level OpenDisplay applied (the software floor
///   included) but never as confirmed by the display: nothing on the display can report it.
/// - No read-back is `sent`: accepted, unconfirmed.
public enum BrightnessSettlement {
    public struct Verdict: Hashable, Sendable {
        public var outcome: OperationOutcome
        /// The level the display is at afterwards, when anything says.
        public var observed: AutomationLevel?
        /// True only when the display itself reported the requested level.
        public var verifiedByDisplay: Bool
        public var note: String?
    }

    public static func settle(_ report: BrightnessWriteReport) -> Verdict {
        guard report.accepted else {
            return Verdict(outcome: .failed, observed: nil, verifiedByDisplay: false,
                           note: report.failure ?? "the write failed")
        }
        let requested = report.requested
        switch report.readback {
        case .none:
            return Verdict(outcome: .sent, observed: nil, verifiedByDisplay: false, note: "no read-back")
        case .level(let value):
            guard let observed = AutomationLevel(normalized: value) else {
                return Verdict(outcome: .sent, observed: nil, verifiedByDisplay: false, note: "unreadable read-back")
            }
            if observed.wholePercent == requested.wholePercent {
                return Verdict(outcome: .verified, observed: observed, verifiedByDisplay: true, note: nil)
            }
            return Verdict(outcome: .sent, observed: observed, verifiedByDisplay: false,
                           note: "the display reports \(observed.wholePercent)%")
        case .ddc(let current, let max):
            guard let observed = AutomationLevel(raw: current, maximum: max) else {
                return Verdict(outcome: .sent, observed: nil, verifiedByDisplay: false, note: "unreadable DDC read-back")
            }
            let target = requested.raw(maximum: max)
            if DDCWriteVerification.outcome(target: target, readback: current, tolerance: 1) == .applied {
                return Verdict(outcome: .verified, observed: observed, verifiedByDisplay: true, note: nil)
            }
            return Verdict(outcome: .sent, observed: observed, verifiedByDisplay: false,
                           note: "the panel reports \(current)/\(max) instead of \(target)")
        case .applied(let value):
            let observed = AutomationLevel(normalized: value)
            var note = "software dimming: the level OpenDisplay applies; the display can't report it"
            if let observed, observed.wholePercent != requested.wholePercent {
                note += " (applied \(observed.wholePercent)%)"
            }
            return Verdict(outcome: .sent, observed: observed, verifiedByDisplay: false, note: note)
        }
    }
}
