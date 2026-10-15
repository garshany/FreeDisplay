import DisplayDomain
import Foundation

/// Original `opendisplay list --json` row. Keep its names and string formatting for existing scripts.
public struct LegacyDisplayListRow: Hashable, Sendable, Codable {
    public var id: String
    public var recordId: String
    public var alias: String?
    public var tags: [String]
    public var cgDisplayID: UInt32?
    public var active: Bool
    public var main: Bool
    public var managedOffline: Bool
    public var displayClass: String
    public var mode: String?
    public var origin: String

    public init(_ observation: DisplayObservation, registryID: DisplayRecordID?, alias: String?,
                tags: Set<String>, managedOffline: Bool) {
        id = observation.recordID.rawValue
        recordId = (registryID ?? observation.recordID).rawValue
        self.alias = alias; self.tags = tags.sorted()
        cgDisplayID = observation.cgDisplayID
        active = observation.isActive; main = observation.isMain
        self.managedOffline = managedOffline
        displayClass = observation.displayClass.rawValue
        mode = observation.mode.map { "\($0.pixelWidth)x\($0.pixelHeight)@\(Int($0.refreshHz.rounded()))" }
        origin = "(\(observation.origin.x),\(observation.origin.y))"
    }
}

public enum LegacyDisplayListRenderer {
    public static func rows(from result: AutomationResult) throws -> [LegacyDisplayListRow] {
        if let issue = result.issue { throw issue }
        guard let displays = result.displays else {
            throw AutomationIssue(.executionFailed, "Display list response has no display rows")
        }
        return try displays.map {
            guard let row = $0.legacyListRow else {
                throw AutomationIssue(.executionFailed, "Display list response is missing legacy metadata")
            }
            return row
        }.sorted { $0.id < $1.id }
    }
}
