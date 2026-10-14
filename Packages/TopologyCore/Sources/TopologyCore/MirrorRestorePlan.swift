import DisplayDomain
import Foundation

/// Orders the mirror writes that put saved mirror relationships back — for Protected Layout and for
/// the keep/revert window alike. Pure, so the three-display cases are unit-tested; the host resolves
/// fresh Core Graphics IDs for each step and performs the writes.
public enum MirrorRestorePlan {
    /// `target` should mirror exactly `source`, or be an independent desktop when `source` is nil.
    public struct Step: Hashable, Sendable {
        public let target: DisplayRecordID
        public let source: DisplayRecordID?

        public init(target: DisplayRecordID, source: DisplayRecordID?) {
            self.target = target
            self.source = source
        }
    }

    /// The writes needed to reach `wanted` from `current`, un-mirroring steps first so every source
    /// is an independent desktop before anything is mirrored onto it. Dropped:
    /// - a target that isn't present, or already mirrors exactly the wanted source;
    /// - a step naming the target as its own source;
    /// - a step whose saved source isn't present now (a missing source can't be substituted —
    ///   least of all by "whatever is main" — and the caller's residual check reports it).
    public static func steps(wanted: [Step], current: TopologySnapshot) -> [Step] {
        var seen = Set<DisplayRecordID>()
        let needed = wanted.filter { step in
            guard seen.insert(step.target).inserted,
                  let live = current.observation(for: step.target),
                  live.mirrorSourceID != step.source else { return false }
            guard let source = step.source else { return true }
            return source != step.target && current.observation(for: source) != nil
        }
        return needed.filter { $0.source == nil } + needed.filter { $0.source != nil }
    }
}
