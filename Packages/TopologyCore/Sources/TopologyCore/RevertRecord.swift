import DisplayDomain
import Foundation

/// The original settings and their age survive a narrowed absent-display record. Legacy markers
/// were observation arrays; their file date is the only available age, so it is kept as such.
public struct RevertRecord: Codable, Hashable, Sendable {
    public var observations: [DisplayObservation]
    public var createdAt: Date?

    public init(observations: [DisplayObservation], createdAt: Date?) {
        self.observations = observations
        self.createdAt = createdAt
    }

    public static func decode(_ data: Data, legacyDate: Date?) -> RevertRecord? {
        let decoder = JSONDecoder()
        if let record = try? decoder.decode(Self.self, from: data) { return record }
        return (try? decoder.decode([DisplayObservation].self, from: data)).map {
            Self(observations: $0, createdAt: legacyDate)
        }
    }

    public func retaining(after outcome: RevertMarkerPolicy.Outcome) -> RevertRecord? {
        RevertMarkerPolicy.recordToKeep(observations, after: outcome).map {
            Self(observations: $0, createdAt: createdAt)
        }
    }
}

/// Presentation is data only: the UI localizes the settings and can show an unreadable marker too,
/// so a corrupt record can still be explicitly forgotten rather than silently hidden.
public struct RevertRecordPresentation: Hashable, Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: DisplayRecordID { observation.recordID }
        public var observation: DisplayObservation
        public var awaitingDisplay: Bool
    }
    public var createdAt: Date?
    public var entries: [Entry]
    public var readable: Bool

    public init(record: RevertRecord?, current: [DisplayObservation]) {
        createdAt = record?.createdAt
        readable = record != nil
        let observations = record?.observations ?? []
        let awaited = Set(RevertMarkerPolicy.mismatches(wanted: observations, current: current).compactMap { mismatch in
            if case .absent(let id) = mismatch { return id }
            return nil as DisplayRecordID?
        })
        entries = observations.map {
            Entry(observation: $0, awaitingDisplay: awaited.contains($0.recordID))
        }
    }
}
