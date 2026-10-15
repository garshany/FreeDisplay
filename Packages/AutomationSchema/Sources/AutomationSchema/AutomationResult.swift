import DisplayDomain
import Foundation

/// A display as automation output lists it. Deliberately without vendor/product/serial: those are
/// identity evidence for matching, not something every client needs to see.
public struct AutomationDisplaySummary: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var alias: String?
    public var tags: [String]
    public var groups: [String]
    public var availability: AutomationDisplayCandidate.Availability
    public var isMain: Bool
    public var isBuiltIn: Bool
    public var cgDisplayID: UInt32?

    public init(_ candidate: AutomationDisplayCandidate) {
        id = candidate.id.rawValue
        name = candidate.name
        alias = candidate.alias
        tags = candidate.tags.sorted()
        groups = candidate.groups.sorted()
        availability = candidate.availability
        isMain = candidate.isMain
        isBuiltIn = candidate.isBuiltIn
        cgDisplayID = candidate.cgDisplayID
    }
}

/// Admission is distinct from a successful device probe or a promise a later write will succeed.
public struct AutomationCommandAvailability: Hashable, Sendable, Codable {
    public var command: AutomationCommandName
    public var issue: AutomationIssue?
    public var admitted: Bool { issue == nil }
}

public struct AutomationCapabilityReport: Hashable, Sendable, Codable {
    public var displayId: String
    public var surface: AutomationSurface
    public var commands: [AutomationCommandAvailability]
    public var brightnessRoutes: BrightnessRouteAvailability
}

/// A brightness read or write as it settled.
public struct AutomationBrightnessReport: Hashable, Sendable, Codable {
    public var displayId: String
    public var displayName: String
    public var route: BrightnessRoute
    /// The absolute level written (for a relative change: where it landed); nil for a read.
    public var requested: AutomationLevel?
    /// The level read back or reported; nil when nothing could be read.
    public var level: AutomationLevel?
    /// What happened to the write; nil for a read.
    public var outcome: OperationOutcome?
    /// True only when the display itself reported `level` (never for software dimming).
    public var reportedByDisplay: Bool
    /// The DDC reading behind `level`, in the monitor's units, when there was one.
    public var raw: Int?
    public var rawMaximum: Int?
    public var note: String?
}

/// One mode as discovery lists it: the mode, its exact key (what `setMode` and Intents store) and
/// whether it is the current one.
public struct AutomationModeEntry: Hashable, Sendable, Codable {
    public var key: String
    public var mode: DisplayMode
    public var isCurrent: Bool

    public init(mode: DisplayMode, isCurrent: Bool) {
        key = FavoriteResolutions.key(for: mode)
        self.mode = mode
        self.isCurrent = isCurrent
    }
}

/// What a display offers right now, as a surface's primitive reports it.
public struct AutomationModeState: Hashable, Sendable, Codable {
    public var current: DisplayMode?
    /// Every exact mode offered, in the order discovery lists them.
    public var offered: [DisplayMode]

    public init(current: DisplayMode?, offered: [DisplayMode]) {
        self.current = current
        self.offered = offered
    }
}

public struct AutomationModeList: Hashable, Sendable, Codable {
    public var displayId: String
    public var displayName: String
    public var current: AutomationModeEntry?
    /// Current mode first, then every other offered mode.
    public var available: [AutomationModeEntry]
}

/// How a mode change settled.
public enum AutomationModeSettlement: Hashable, Sendable, Codable {
    /// The display was already in the mode; nothing changed.
    case alreadyInEffect
    /// macOS confirmed the mode; it stays only if kept before the countdown ends.
    case awaitingConfirmation(secondsToKeep: Int?)
    /// macOS confirmed the mode and nothing more is pending.
    case applied
}

public struct AutomationModeReport: Hashable, Sendable, Codable {
    public enum Settlement: String, Hashable, Sendable, Codable {
        case alreadyInEffect, awaitingConfirmation, applied
    }

    public var displayId: String
    public var displayName: String
    public var mode: AutomationModeEntry
    public var settlement: Settlement
    public var secondsToKeep: Int?
}

/// How a main-display change settled, as a surface's primitive reports it.
public struct AutomationMainSettlement: Hashable, Sendable, Codable {
    /// The main display observed afterwards.
    public var observedMain: DisplayRecordID?
    /// True when the change stays only if kept before a keep-or-revert countdown ends.
    public var awaitingConfirmation: Bool
    public var secondsToKeep: Int?

    public init(observedMain: DisplayRecordID?, awaitingConfirmation: Bool = false, secondsToKeep: Int? = nil) {
        self.observedMain = observedMain
        self.awaitingConfirmation = awaitingConfirmation
        self.secondsToKeep = secondsToKeep
    }
}

public struct AutomationMainReport: Hashable, Sendable, Codable {
    public var displayId: String
    public var displayName: String
    /// False when the display already was the main display.
    public var changed: Bool
    /// True when the change reverts unless it is kept in time.
    public var awaitingConfirmation: Bool
    public var secondsToKeep: Int?
}

/// A display's ICC assignment as ColorSync reports it.
public struct AutomationColorProfileState: Hashable, Sendable, Codable {
    /// The profile in effect, by its description.
    public var name: String?
    /// The user-assigned profile file, when one overrides the factory profile.
    public var customProfilePath: String?
    public var isFactory: Bool
    /// Whether ColorSync exposes a device for the display, so a profile can be assigned at all.
    public var controllable: Bool

    public init(name: String?, customProfilePath: String?, isFactory: Bool, controllable: Bool) {
        self.name = name
        self.customProfilePath = customProfilePath
        self.isFactory = isFactory
        self.controllable = controllable
    }
}

public struct AutomationColorProfileReport: Hashable, Sendable, Codable {
    public var displayId: String
    public var displayName: String
    public var state: AutomationColorProfileState
    /// For a change: false when the display already had it.
    public var changed: Bool?
}

/// The settled result of one request — what every surface renders (FD-066). The `envelope` is the
/// stable per-target record (`ResultEnvelope`, shared with scenes and recovery); the typed reports
/// carry what a reader of that command needs; `issue` says why it didn't (fully) happen.
public struct AutomationResult: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = "1.0"

    public var schemaVersion: String
    public var command: AutomationCommandName
    public var dryRun: Bool
    public var issue: AutomationIssue?
    public var envelope: ResultEnvelope
    public var displays: [AutomationDisplaySummary]?
    public var capabilities: AutomationCapabilityReport?
    public var brightness: AutomationBrightnessReport?
    public var contrast: AutomationBrightnessReport?
    public var modes: AutomationModeList?
    public var mode: AutomationModeReport?
    public var main: AutomationMainReport?
    public var colorProfile: AutomationColorProfileReport?
    public var colorProfiles: [AutomationProfileInfo]?
    public var integrationSample: IntegrationSample?
    /// For a dry run: what would have been done.
    public var plan: String?

    public init(command: AutomationCommandName, envelope: ResultEnvelope, issue: AutomationIssue? = nil,
                dryRun: Bool = false) {
        schemaVersion = Self.currentSchemaVersion
        self.command = command
        self.envelope = envelope
        self.issue = issue
        self.dryRun = dryRun
    }

    public var status: ResultEnvelope.Status { envelope.status }

    /// True when everything asked for happened, was already so, or was accepted unconfirmed.
    public var succeeded: Bool { issue == nil && (status == .committed || status == .noOp) }
}

// MARK: - Surface mappings

public extension CLIExitCode {
    /// The exit status a settled result implies: a malformed request is a usage error (2) even though
    /// it reached the engine; everything else follows the envelope status.
    init(_ result: AutomationResult) {
        if result.issue?.category == .usage {
            self = .usage
        } else {
            self.init(result.status)
        }
    }
}

/// The HTTP status for a settled result (TB-36: a rejected request is never a 200 the client has to
/// see through). 2xx means the request was carried out (207: partly); 4xx means it was refused
/// before anything changed; 5xx means it was attempted and failed or couldn't be confirmed.
public enum AutomationHTTPStatus {
    public static func code(for result: AutomationResult) -> Int {
        if let issue = result.issue { return code(for: issue) }
        switch result.status {
        case .committed, .noOp: return 200
        case .partial: return 207
        case .failed, .rolledBack: return 502
        }
    }

    public static func code(for issue: AutomationIssue) -> Int {
        switch issue.code {
        case .unknownCommand, .displayNotFound, .unknownGroup, .profileNotFound:
            return 404
        case .unknownParameter, .missingParameter, .conflictingParameters, .invalidValue, .invalidSelector:
            return 400
        case .ambiguousSelector, .ambiguousMode, .ambiguousProfile, .displayNotConnected, .displayInactive,
             .busy, .confirmationRequired:
            return 409
        case .unsupportedSelector, .methodUnavailable, .capabilityUnavailable, .modeNotOffered:
            return 422
        case .refusedFromSurface:
            return 403
        case .notReady:
            return 503
        case .executionFailed, .notConfirmed:
            return 502
        }
    }

    /// A short reason phrase for the status line.
    public static func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 207: return "Multi-Status"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 422: return "Unprocessable Content"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Rejected"
        }
    }
}

/// The outcome word App Intents return so a shortcut can branch without parsing a dialog (IN-07).
public enum AutomationOutcomeKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// Done, and the display confirmed it (or it was a read that succeeded).
    case done
    /// Accepted, but nothing confirmed the effect (no or disagreeing read-back, software dimming).
    case requested
    /// Nothing to do: already so.
    case alreadyInEffect
    /// Some of it happened.
    case partial
    /// Refused or failed; nothing (more) changed.
    case failed

    public init(_ result: AutomationResult) {
        if result.issue != nil {
            self = result.status == .partial ? .partial : .failed
            return
        }
        switch result.status {
        case .noOp:
            let outcomes = result.envelope.targets.flatMap(\.operations).compactMap(\.outcome)
            self = outcomes.contains(.alreadySatisfied) ? .alreadyInEffect : .done
        case .committed:
            let outcomes = result.envelope.targets.flatMap(\.operations).compactMap(\.outcome)
            self = outcomes.contains(.sent) ? .requested : .done
        case .partial: self = .partial
        case .failed, .rolledBack: self = .failed
        }
    }
}

public extension AutomationResult {
    /// The canonical JSON encoding (sorted keys, ISO-8601 dates) — the same encoder envelopes use.
    func jsonData(prettyPrinted: Bool = true) -> Data {
        let encoder = ResultEnvelope.makeEncoder()
        if !prettyPrinted { encoder.outputFormatting = [.sortedKeys] }
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}
