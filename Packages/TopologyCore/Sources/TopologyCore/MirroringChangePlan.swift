import DisplayDomain

/// A user mirroring request keeps UUIDs rather than transient Core Graphics display numbers.
/// A whole request owns one arrangement rollback window, including multi-display unmirroring.
public struct MirroringChangePlan: Sendable {
    public enum Outcome: Equatable, Sendable { case awaitingConfirmation, restorePrevious }

    private let targets: [String]
    private let source: String?

    public init?(targets: [DisplayObservation], source: DisplayObservation?) {
        guard !targets.isEmpty else { return nil }
        let identities = targets.compactMap { $0.cgUUID }.filter { !$0.isEmpty }
        guard identities.count == targets.count, Set(identities).count == targets.count else { return nil }
        if let source {
            guard let uuid = source.cgUUID, !uuid.isEmpty, !identities.contains(uuid) else { return nil }
            self.source = uuid
        } else { self.source = nil }
        self.targets = identities
    }

    private func resolve(_ uuid: String, in observations: [DisplayObservation]) -> DisplayObservation? {
        let matches = observations.filter { $0.cgUUID == uuid }
        guard matches.count == 1, let match = matches.first, match.isActive,
              let number = match.cgDisplayID,
              observations.filter({ $0.cgDisplayID == number }).count == 1 else { return nil }
        return match
    }

    public func isResolvable(in observations: [DisplayObservation]) -> Bool {
        targets.allSatisfy { resolve($0, in: observations) != nil }
            && (source.map { resolve($0, in: observations) != nil } ?? true)
    }

    /// The provider runs this without suspension. Each step gets a fresh topology immediately
    /// before its write; a preceding operation may have removed or replaced another target.
    public func apply(read: () -> [DisplayObservation], write: (UInt32, UInt32?) -> Bool) -> Bool {
        for uuid in targets {
            let current = read()
            guard let target = resolve(uuid, in: current), let number = target.cgDisplayID else { return false }
            var sourceNumber: UInt32?
            if let source {
                guard let live = resolve(source, in: current), live.mirrorSourceID == nil,
                      let number = live.cgDisplayID else { return false }
                sourceNumber = number
            }
            guard write(number, sourceNumber) else { return false }
        }
        return true
    }

    /// A successful provider return alone cannot offer Keep: readback must confirm every target.
    public func outcome(accepted: Bool, current: [DisplayObservation]) -> Outcome {
        guard accepted, isResolvable(in: current) else { return .restorePrevious }
        let sourceID = source.flatMap { resolve($0, in: current)?.recordID }
        return targets.allSatisfy { resolve($0, in: current)?.mirrorSourceID == sourceID }
            ? .awaitingConfirmation : .restorePrevious
    }
}
