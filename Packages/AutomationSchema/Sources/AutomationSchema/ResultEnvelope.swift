import DisplayDomain
import Foundation

/// The stable, versioned result envelope returned by every automation surface (CLI, App Intents,
/// HTTP API). Schema is versioned independently of the app; clients must ignore unknown fields
/// (PRD §12.4, §12.7, AUT-003/004/012).
public struct ResultEnvelope: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = "1.0"

    public enum Status: String, Hashable, Sendable, Codable {
        case committed
        case partial
        case rolledBack
        case failed
        case noOp
    }

    public var schemaVersion: String
    public var transactionId: String
    public var status: Status
    public var actor: Actor
    public var requestedAt: Date
    public var topologyGeneration: UInt64
    public var targets: [TargetResult]
    public var recovery: RecoveryInfo?
    public var errors: [ErrorInfo]

    public init(
        schemaVersion: String = ResultEnvelope.currentSchemaVersion,
        transactionId: String,
        status: Status,
        actor: Actor,
        requestedAt: Date,
        topologyGeneration: UInt64,
        targets: [TargetResult] = [],
        recovery: RecoveryInfo? = nil,
        errors: [ErrorInfo] = []
    ) {
        self.schemaVersion = schemaVersion
        self.transactionId = transactionId
        self.status = status
        self.actor = actor
        self.requestedAt = requestedAt
        self.topologyGeneration = topologyGeneration
        self.targets = targets
        self.recovery = recovery
        self.errors = errors
    }

    public struct TargetResult: Hashable, Sendable, Codable {
        public var displayId: String
        public var alias: String?
        public var identityConfidence: Double
        public var operations: [OperationResult]

        public init(displayId: String, alias: String?, identityConfidence: Double, operations: [OperationResult]) {
            self.displayId = displayId
            self.alias = alias
            self.identityConfidence = identityConfidence
            self.operations = operations
        }
    }

    public struct OperationResult: Hashable, Sendable, Codable {
        public var field: String
        public var requested: AnyCodableValue?
        public var observed: AnyCodableValue?
        public var verification: VerificationState
        public var provider: String?
        public var warnings: [String]
        /// What happened to this field — finer than `verification`, which only says whether a read
        /// confirmed it. Optional and additive: envelopes written before it existed decode as nil,
        /// and older clients ignore it.
        public var outcome: OperationOutcome?

        public init(
            field: String,
            requested: AnyCodableValue? = nil,
            observed: AnyCodableValue? = nil,
            verification: VerificationState,
            provider: String? = nil,
            warnings: [String] = [],
            outcome: OperationOutcome? = nil
        ) {
            self.field = field
            self.requested = requested
            self.observed = observed
            self.verification = verification
            self.provider = provider
            self.warnings = warnings
            self.outcome = outcome
        }
    }

    public struct RecoveryInfo: Hashable, Sendable, Codable {
        public var checkpointId: String
        public var available: Bool

        public init(checkpointId: String, available: Bool) {
            self.checkpointId = checkpointId
            self.available = available
        }
    }

    public struct ErrorInfo: Hashable, Sendable, Codable {
        public var code: String
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }
}

/// What happened to one requested field. `sent` and `verified` are kept apart on purpose: a DDC
/// monitor ACKs writes it then ignores, and DisplayServices accepting a level is not a panel
/// showing it, so only a read-back that agrees earns `verified`.
public enum OperationOutcome: String, Hashable, Sendable, Codable {
    /// Written, and a read-back shows the requested value.
    case verified
    /// The provider accepted the write; nothing confirmed it took (no read-back, or one that
    /// disagreed — the panel may still be applying it, or may have ignored it).
    case sent
    /// Nothing to do: the display already had the requested value.
    case alreadySatisfied
    /// Not attempted: this surface does not apply the field, or its target is absent.
    case skipped
    /// The display has no route for this control.
    case unsupported
    /// The provider rejected or failed the write, or the result shows the change did not happen.
    case failed

    /// True when the field ended up as requested, or was accepted for writing.
    public var isSuccess: Bool {
        switch self {
        case .verified, .sent, .alreadySatisfied: return true
        case .skipped, .unsupported, .failed: return false
        }
    }
}

public extension ResultEnvelope.Status {
    /// The envelope status a set of per-field outcomes adds up to. Anything short of every field
    /// succeeding is reported, never rounded up to `committed`: some success plus any problem is
    /// `partial`, problems alone are `failed`, and nothing to do (or only already-satisfied
    /// fields) is `noOp`.
    static func aggregate(_ outcomes: [OperationOutcome]) -> ResultEnvelope.Status {
        guard !outcomes.isEmpty else { return .noOp }
        let problems = outcomes.filter { !$0.isSuccess }.count
        if problems == 0 {
            return outcomes.allSatisfy { $0 == .alreadySatisfied } ? .noOp : .committed
        }
        return problems == outcomes.count ? .failed : .partial
    }
}

public extension ResultEnvelope {
    /// The reconnect-all result every surface returns (UI, HTTP, URL, App Intent, CLI): one target
    /// per display attempted, `verified` only when the display was seen back. A display that was
    /// asked to reconnect and did not come back is a failure, never folded into `committed`.
    static func reconnectAll(
        results: [(displayId: String, reconnected: Bool)], actor: Actor, requestedAt: Date,
        topologyGeneration: UInt64
    ) -> ResultEnvelope {
        let targets = results.map { result in
            TargetResult(
                displayId: result.displayId, alias: nil, identityConfidence: 1.0,
                operations: [.init(field: "reconnect",
                                   verification: result.reconnected ? .verified : .readBackUnavailable,
                                   outcome: result.reconnected ? .verified : .failed)])
        }
        let failed = results.filter { !$0.reconnected }.map(\.displayId)
        return ResultEnvelope(
            transactionId: "txn_reconnectAll",
            status: .aggregate(results.map { $0.reconnected ? .verified : .failed }),
            actor: actor, requestedAt: requestedAt, topologyGeneration: topologyGeneration,
            targets: targets,
            errors: failed.map { .init(code: "notReconnected", message: "\($0) did not come back") })
    }
}

/// A minimal JSON value wrapper so operation `requested`/`observed` can carry bool/number/string
/// without leaking concrete Swift types into the wire schema.
public enum AnyCodableValue: Hashable, Sendable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

public extension ResultEnvelope {
    /// Canonical encoder used across all automation surfaces: stable key order + ISO-8601 dates.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
