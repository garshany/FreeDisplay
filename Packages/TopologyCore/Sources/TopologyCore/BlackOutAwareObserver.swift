import DisplayDomain
import Foundation
import ProviderInterfaces

/// The topology as the lifecycle safeguards must judge it: a provider's snapshots with the app's
/// Black Out stamped in (`BlackOutPolicy.stamping`).
///
/// No provider can observe Black Out — it is the host process's own click-through overlay and gamma
/// floor — so every observation arrives `.visible`, and a coordinator reading the provider directly
/// would accept a blacked-out screen as the safe surface a disconnect leaves the user on. Handing
/// the coordinator this wrapper instead is what lets `SafetyEngine`'s non-bypassable preflight see
/// it, whichever entry point (menu, hotkey, URL, local HTTP) asked for the disconnect.
///
/// The set is written synchronously by the host the moment Black Out changes and read from the
/// coordinator's actor, hence the lock.
public final class BlackOutAwareObserver: TopologyObserving, @unchecked Sendable {
    private let base: any TopologyObserving
    private let lock = NSLock()
    private var stored: Set<DisplayRecordID> = []

    public init(base: any TopologyObserving) {
        self.base = base
    }

    /// The displays currently blacked out, as the host last reported them.
    public var blackedOut: Set<DisplayRecordID> {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Replaces the blacked-out set; the next snapshot carries it.
    public func setBlackedOut(_ ids: Set<DisplayRecordID>) {
        lock.lock()
        stored = ids
        lock.unlock()
    }

    public func currentSnapshot() async -> TopologySnapshot {
        stamped(await base.currentSnapshot())
    }

    public func awaitStableGeneration(after generation: TopologyGeneration) async -> TopologySnapshot {
        stamped(await base.awaitStableGeneration(after: generation))
    }

    /// Read after the base snapshot, so a blackout lifted or set while it was being taken is the one
    /// that counts.
    private func stamped(_ snapshot: TopologySnapshot) -> TopologySnapshot {
        var snapshot = snapshot
        snapshot.observations = BlackOutPolicy.stamping(blackedOut, into: snapshot.observations)
        return snapshot
    }
}
