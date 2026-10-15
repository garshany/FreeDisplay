import Foundation

/// Why an automation request did not (fully) happen — one vocabulary for every surface (FD-066).
///
/// The CLI, the URL scheme, the local HTTP control and the App Intents used to word their own
/// refusals, so "no such display", "ambiguous selector" and "this display can't do that" read
/// differently everywhere and could not be told apart by a script. An issue carries a stable
/// machine `code` (the contract — scripts branch on it), its `category` (which decides the CLI exit
/// code and the HTTP status), and an English `message` for logs and machine output. Surfaces that
/// show text to a person (App Intents, alerts) localize from the code, not from the message.
public struct AutomationIssue: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Code: String, Hashable, Sendable, Codable, CaseIterable {
        // The request itself is wrong; nothing ran.
        case unknownCommand
        case unknownParameter
        case missingParameter
        case conflictingParameters
        case invalidValue
        case invalidSelector
        // The target could not be pinned to exactly one usable display.
        case displayNotFound
        case ambiguousSelector
        case unknownGroup
        case unsupportedSelector
        case displayNotConnected
        case displayInactive
        // The display (or this surface) can't do what was asked.
        case methodUnavailable
        case capabilityUnavailable
        case modeNotOffered
        case ambiguousMode
        case profileNotFound
        case ambiguousProfile
        // Policy or current state prevents it right now.
        case busy
        case confirmationRequired
        case refusedFromSurface
        case notReady
        // It was attempted and did not land.
        case executionFailed
        case notConfirmed
    }

    /// What kind of problem it is — the part surfaces map onto their own status words.
    public enum Category: String, Hashable, Sendable, Codable {
        /// Malformed request (CLI exit 2, HTTP 400/404). Nothing ran.
        case usage
        /// The selector resolved to no display, several, or one that isn't usable now.
        case target
        /// The display, its routes or this surface lack the capability.
        case unsupported
        /// Something else is in progress or needs confirmation first.
        case conflict
        /// This surface may not run the command at all.
        case forbidden
        /// The app isn't ready to answer.
        case unavailable
        /// The attempt was made and failed or could not be confirmed.
        case execution
    }

    public var code: Code
    /// English, stable wording for logs and machine output. Never echoes a token or secret.
    public var message: String
    /// The selector, parameter, display or value the issue is about, when there is one.
    public var subject: String?
    /// For ambiguity: the identifiers the request matched, so a client can choose one explicitly.
    public var candidates: [String]

    public init(_ code: Code, _ message: String, subject: String? = nil, candidates: [String] = []) {
        self.code = code
        self.message = message
        self.subject = subject
        self.candidates = candidates
    }

    public var category: Category {
        switch code {
        case .unknownCommand, .unknownParameter, .missingParameter, .conflictingParameters,
             .invalidValue, .invalidSelector:
            return .usage
        case .displayNotFound, .ambiguousSelector, .unknownGroup, .displayNotConnected, .displayInactive:
            return .target
        case .unsupportedSelector, .methodUnavailable, .capabilityUnavailable, .modeNotOffered,
             .ambiguousMode, .profileNotFound, .ambiguousProfile:
            return .unsupported
        case .busy, .confirmationRequired:
            return .conflict
        case .refusedFromSurface:
            return .forbidden
        case .notReady:
            return .unavailable
        case .executionFailed, .notConfirmed:
            return .execution
        }
    }

    public var description: String { message }

    /// The error row a result envelope carries for this issue.
    public var errorInfo: ResultEnvelope.ErrorInfo { .init(code: code.rawValue, message: message) }
}

public extension AutomationIssue {
    static func invalidValue(_ parameter: String, _ detail: String) -> AutomationIssue {
        AutomationIssue(.invalidValue, "\(parameter): \(detail)", subject: parameter)
    }

    static func missing(_ parameter: String, for command: String) -> AutomationIssue {
        AutomationIssue(.missingParameter, "'\(command)' needs '\(parameter)'", subject: parameter)
    }
}
