import DisplayDomain
import Foundation

/// Which displays the drag-to-arrange canvas offers as movable tiles. A mirror target is not a
/// desktop of its own: it shows its source's image at the source's position, and an origin write
/// aimed at it can change which mirror set it belongs to. So each mirror set gets exactly one
/// tile — its source — which carries the targets stacked on it. Pure, so it is unit-tested.
public enum ArrangementTiles {
    public struct Tile: Hashable, Sendable {
        public let display: DisplayObservation
        /// The displays mirroring this one, sorted by record id; they move with it.
        public let mirrorTargets: [DisplayRecordID]

        public init(display: DisplayObservation, mirrorTargets: [DisplayRecordID]) {
            self.display = display
            self.mirrorTargets = mirrorTargets
        }
    }

    /// Active displays with a known mode, minus mirror targets, each with its stacked targets.
    public static func tiles(for observations: [DisplayObservation]) -> [Tile] {
        let shown = observations.filter { $0.isActive && $0.mode != nil }
        var targets: [DisplayRecordID: [DisplayRecordID]] = [:]
        for observation in shown {
            if let source = observation.mirrorSourceID { targets[source, default: []].append(observation.recordID) }
        }
        return shown
            .filter { $0.mirrorSourceID == nil }
            .map { Tile(display: $0, mirrorTargets: (targets[$0.recordID] ?? []).sorted { $0.rawValue < $1.rawValue }) }
    }

    /// Whether a drop may still move `id`, judged against the topology read at drop time — the tile
    /// was drawn from an older one, and the display may have left or become a mirror target since.
    public static func canMove(_ id: DisplayRecordID, in snapshot: TopologySnapshot) -> Bool {
        guard let live = snapshot.observation(for: id) else { return false }
        return live.isActive && live.mirrorSourceID == nil && live.cgDisplayID != nil
    }
}
