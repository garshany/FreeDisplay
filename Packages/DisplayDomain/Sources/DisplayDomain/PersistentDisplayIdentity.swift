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
