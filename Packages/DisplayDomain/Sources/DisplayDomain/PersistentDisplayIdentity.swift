import Foundation

/// Observation numbers are reusable addresses, never evidence of ownership. Older entries stay
/// archived under their original keys, but all persistent feature readers must leave them inert.
public enum PersistentDisplayIdentity {
    public static func isPersistent(_ id: DisplayRecordID) -> Bool {
        let raw = id.rawValue
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !raw.hasPrefix("cgid:"), !raw.hasPrefix("unresolved:") else { return false }
        if let uuid = id.cgUUID { return !uuid.isEmpty }
        return true
    }

    /// A live association also requires the registry's unambiguous answer. In particular, a
    /// syntactically stable observation UUID must not bypass a provisional registry resolution.
    public static func isVerified(_ observationID: DisplayRecordID, record: DisplayRecord?) -> Bool {
        isPersistent(observationID) && record.map { !$0.isProvisional && isPersistent($0.id) } == true
    }
}

/// Live refusals and work in flight must shadow remembered ownership, even when the observation
/// UUID is unchanged. Generations prevent a slower refresh from authorizing an obsolete topology.
public struct LiveDisplayIdentityState: Sendable {
    public enum Resolution: Sendable {
        case pending, unresolved, verified(DisplayRecord)
    }

    private var generation = UUID()
    public private(set) var resolutions: [DisplayRecordID: Resolution] = [:]

    public init() {}

    public mutating func begin(connected: [DisplayRecordID]) -> UUID {
        generation = UUID()
        resolutions = Dictionary(connected.map { ($0, .pending) }, uniquingKeysWith: { first, _ in first })
        return generation
    }

    @discardableResult
    public mutating func updateConnected(_ connected: [DisplayRecordID], generation: UUID) -> Bool {
        guard generation == self.generation else { return false }
        resolutions = Dictionary(connected.map { ($0, .pending) }, uniquingKeysWith: { first, _ in first })
        return true
    }

    @discardableResult
    public mutating func complete(_ records: [DisplayRecordID: DisplayRecord], generation: UUID) -> Bool {
        guard generation == self.generation else { return false }
        for id in resolutions.keys {
            if let record = records[id], PersistentDisplayIdentity.isVerified(id, record: record) {
                resolutions[id] = .verified(record)
            } else {
                resolutions[id] = .unresolved
            }
        }
        return true
    }

    public func isVerified(_ id: DisplayRecordID, remembered: DisplayRecord?) -> Bool {
        switch resolutions[id] {
        case .pending?, .unresolved?: return false
        case .verified(let record)?: return PersistentDisplayIdentity.isVerified(id, record: record)
        case nil: return PersistentDisplayIdentity.isVerified(id, record: remembered)
        }
    }
}
