import DisplayDomain
import Foundation

/// How a live display claims a remembered record, weakest first. Comparable so a record two present
/// displays both claim can go to the one with the better evidence (`DisplayRegistry`).
public enum IdentityMatchEvidence: Int, Hashable, Sendable, Comparable, CaseIterable {
    /// The single best similarity score at or above the recognition threshold.
    case scored
    /// This Mac's display UUID already pointed at the record (the same-Mac fast path).
    case cgUUID
    /// The same serial number from the same vendor and model.
    case serial
    /// The same qualified serial, and this Mac's display UUID points at the same record.
    case serialAndCGUUID

    public static func < (lhs: IdentityMatchEvidence, rhs: IdentityMatchEvidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Why a remembered record cannot be a given display: its own identity names another one
/// (`IdentityScorer.identitiesConflict`). Such a record takes part in no matching stage.
public enum IdentityConflict: String, Hashable, Sendable {
    case differentVendorOrModel
    case differentSerial

    public static func between(_ a: DisplayFingerprint, _ b: DisplayFingerprint) -> IdentityConflict? {
        guard IdentityScorer.identitiesConflict(a, b) else { return nil }
        return a.vendorID != b.vendorID || a.productID != b.productID ? .differentVendorOrModel : .differentSerial
    }
}

/// One field of identity evidence compared between what a record remembers and what a display
/// reports now — the "before/after fingerprint" a diagnosis starts from (TB-09/TB-13).
public struct FingerprintFieldComparison: Hashable, Sendable {
    public enum Field: String, Hashable, Sendable, CaseIterable {
        case vendor, product, serial, modelName, manufactureDate, physicalSize, edid
    }

    public enum Agreement: String, Hashable, Sendable {
        case same
        case different
        /// The record has a value; the display doesn't report one now.
        case onlyRemembered
        /// The display reports a value the record never had.
        case onlyCurrent
        /// Neither side has it.
        case neither
    }

    public var field: Field
    public var agreement: Agreement

    public init(field: Field, agreement: Agreement) {
        self.field = field
        self.agreement = agreement
    }
}

/// What two fingerprints say about whether they are one physical unit.
public enum PhysicalIdentity: String, Hashable, Sendable {
    /// Same vendor, model and serial — the strongest evidence a display offers, still not proof:
    /// some monitors ship with a placeholder serial shared by every unit.
    case sameSerial
    /// Their vendor, model or qualified serial positively differ: two different displays.
    case differentDisplays
    /// Too little evidence either way (no serial on one side, say).
    case undetermined
}

public enum FingerprintComparison {
    /// Field by field: what the record remembers against what the display reports.
    public static func compare(remembered: DisplayFingerprint,
                               current: DisplayFingerprint) -> [FingerprintFieldComparison] {
        func agreement<T: Equatable>(_ old: T?, _ new: T?) -> FingerprintFieldComparison.Agreement {
            switch (old, new) {
            case (nil, nil): return .neither
            case (.some, nil): return .onlyRemembered
            case (nil, .some): return .onlyCurrent
            case let (.some(a), .some(b)): return a == b ? .same : .different
            }
        }
        struct Pair: Equatable { let a: Int?, b: Int? }
        func pair(_ a: Int?, _ b: Int?) -> Pair? { a == nil && b == nil ? nil : Pair(a: a, b: b) }
        return [
            .init(field: .vendor, agreement: agreement(remembered.vendorID, current.vendorID)),
            .init(field: .product, agreement: agreement(remembered.productID, current.productID)),
            .init(field: .serial, agreement: agreement(remembered.serialNumber ?? remembered.serialHash,
                                                       current.serialNumber ?? current.serialHash)),
            .init(field: .modelName, agreement: agreement(remembered.modelName, current.modelName)),
            .init(field: .manufactureDate, agreement: agreement(
                pair(remembered.manufactureYear, remembered.manufactureWeek),
                pair(current.manufactureYear, current.manufactureWeek))),
            .init(field: .physicalSize, agreement: agreement(
                pair(remembered.physicalWidthMM, remembered.physicalHeightMM),
                pair(current.physicalWidthMM, current.physicalHeightMM))),
            .init(field: .edid, agreement: agreement(remembered.edidHash, current.edidHash)),
        ]
    }

    public static func physicalIdentity(_ a: DisplayFingerprint, _ b: DisplayFingerprint) -> PhysicalIdentity {
        if IdentityScorer.identitiesConflict(a, b) { return .differentDisplays }
        if IdentityScorer.serialsMatch(a, b) { return .sameSerial }
        return .undetermined
    }
}

/// How the registry matched one live display to a remembered record — or why it didn't — stage by
/// stage, with every remembered record's own verdict (SD-10, FA-11, TB-09). The decision is the one
/// `DisplayRegistry` acted on: the registry derives its answer from this very value.
public struct IdentityMatchExplanation: Hashable, Sendable {
    public enum Decision: Hashable, Sendable {
        case record(DisplayRecordID, IdentityMatchEvidence)
        /// No record was attached: the display couldn't be told apart from these.
        case ambiguous([DisplayRecordID], AmbiguityReason)
        /// Nothing remembered matched; a record was minted.
        case newRecord
    }

    public enum AmbiguityReason: String, Hashable, Sendable {
        /// Several records share the qualified serial and this Mac's UUID points at none of them.
        case sharedSerial
        /// Two or more records tie for the best score.
        case tiedScore
        /// Another display present at the same time claimed the same record with equal or
        /// stronger evidence.
        case claimedByAnotherDisplay
    }

    /// One remembered record, judged against the live display.
    public struct Assessment: Hashable, Sendable {
        public var recordID: DisplayRecordID
        /// Set when the record names another display: it took part in no stage.
        public var conflict: IdentityConflict?
        /// Same serial from the same vendor and model.
        public var serialMatches: Bool
        /// This Mac's UUID for the live display points at the record.
        public var indexedUnderThisUUID: Bool
        /// The similarity score and the evidence behind it.
        public var confidence: IdentityConfidence
        /// The record's remembered fingerprint against the live one, before this resolve merged them.
        public var fields: [FingerprintFieldComparison]
        /// Another display present at the same time holds this record, so it was out of the running.
        public var heldByAnotherDisplay: Bool

        public init(recordID: DisplayRecordID, conflict: IdentityConflict?, serialMatches: Bool,
                    indexedUnderThisUUID: Bool, confidence: IdentityConfidence,
                    fields: [FingerprintFieldComparison], heldByAnotherDisplay: Bool = false) {
            self.recordID = recordID
            self.conflict = conflict
            self.serialMatches = serialMatches
            self.indexedUnderThisUUID = indexedUnderThisUUID
            self.confidence = confidence
            self.fields = fields
            self.heldByAnotherDisplay = heldByAnotherDisplay
        }
    }

    public var decision: Decision
    /// What the display reported when it was matched.
    public var observed: DisplayFingerprint
    public var cgUUID: String?
    public var recognitionThreshold: Double
    /// Every remembered record, in registry order.
    public var assessments: [Assessment]

    public init(decision: Decision, observed: DisplayFingerprint, cgUUID: String?,
                recognitionThreshold: Double, assessments: [Assessment]) {
        self.decision = decision
        self.observed = observed
        self.cgUUID = cgUUID
        self.recognitionThreshold = recognitionThreshold
        self.assessments = assessments
    }

    public func assessment(for id: DisplayRecordID) -> Assessment? {
        assessments.first { $0.recordID == id }
    }

    /// The record the display was matched to, if one was.
    public var matchedRecordID: DisplayRecordID? {
        if case .record(let id, _) = decision { return id }
        return nil
    }
}

/// The registry's matching stages as a pure function, so recognition and its explanation can never
/// disagree. A record that positively conflicts with the observation takes part in none of them:
///   1. serial qualified by vendor and model; when several records share it, the one this CG UUID
///      already points at, else ambiguous,
///   2. the same-Mac CG-UUID fast path,
///   3. the single best score at or above the threshold (a tie is ambiguous),
///   4. otherwise a new record.
/// A numeric display id is never evidence: it is reused across reconnects.
public enum IdentityMatching {
    public static func evaluate(
        fingerprint: DisplayFingerprint,
        cgUUID: String?,
        records: [DisplayRecord],
        cgUUIDIndex: [String: DisplayRecordID],
        excluding excluded: Set<DisplayRecordID> = [],
        recognitionThreshold: Double
    ) -> IdentityMatchExplanation {
        let indexedID = cgUUID.flatMap { cgUUIDIndex[$0] }
        let assessments = records.map { record in
            IdentityMatchExplanation.Assessment(
                recordID: record.id,
                conflict: IdentityConflict.between(fingerprint, record.fingerprint),
                serialMatches: IdentityScorer.serialsMatch(fingerprint, record.fingerprint),
                indexedUnderThisUUID: indexedID == record.id,
                confidence: IdentityScorer.score(observed: fingerprint, candidate: record),
                fields: FingerprintComparison.compare(remembered: record.fingerprint, current: fingerprint),
                heldByAnotherDisplay: excluded.contains(record.id))
        }
        // Out of every stage: a record held by another present display, and one whose own vendor,
        // model or qualified serial says it is a different display — following its CG UUID index
        // entry or its score would merge two displays and hand this one the other's name.
        let candidates = assessments.filter { $0.conflict == nil && !$0.heldByAnotherDisplay }
        let strategies = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.identityStrategy ?? .automatic) })
        let indexed = candidates.first(where: { $0.indexedUnderThisUUID && strategies[$0.recordID] != .qualifiedSerial })?.recordID

        func explained(_ decision: IdentityMatchExplanation.Decision) -> IdentityMatchExplanation {
            IdentityMatchExplanation(decision: decision, observed: fingerprint, cgUUID: cgUUID,
                                     recognitionThreshold: recognitionThreshold, assessments: assessments)
        }

        // 1. Qualified serial.
        let serialMatches = candidates.filter { $0.serialMatches && strategies[$0.recordID] != .systemUUID }.map(\.recordID)
        if serialMatches.count == 1 {
            return explained(.record(serialMatches[0], indexed == serialMatches[0] ? .serialAndCGUUID : .serial))
        }
        if !serialMatches.isEmpty {
            // Identical units, or records the user has already split: only this Mac's UUID can say.
            if let indexed, serialMatches.contains(indexed) { return explained(.record(indexed, .serialAndCGUUID)) }
            return explained(.ambiguous(serialMatches, .sharedSerial))
        }

        // 2. Same-Mac CG-UUID fast path.
        if let indexed { return explained(.record(indexed, .cgUUID)) }

        // 3. The single best score; a tie is an answer of its own.
        let scored = candidates.filter { strategies[$0.recordID] == .automatic && $0.confidence.score >= recognitionThreshold }
        if let best = scored.map(\.confidence.score).max() {
            let top = scored.filter { $0.confidence.score == best }.map(\.recordID)
            return explained(top.count == 1 ? .record(top[0], .scored) : .ambiguous(top, .tiedScore))
        }

        // 4. Nothing remembered matched.
        return explained(.newRecord)
    }
}
