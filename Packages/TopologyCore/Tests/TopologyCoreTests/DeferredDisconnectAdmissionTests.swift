import XCTest
import DisplayDomain
import ProviderInterfaces
import SimulatorProvider
@testable import TopologyCore

private actor PreflightGate {
    private(set) var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { waiter = $0; entered = true }
    }
    func release() { waiter?.resume(); waiter = nil }
}

private struct GatedObserver: TopologyObserving {
    let system: SimulatedDisplaySystem
    let gate: PreflightGate?
    func currentSnapshot() async -> TopologySnapshot {
        let snapshot = await system.currentSnapshot()
        await gate?.pause()
        return snapshot
    }
    func awaitStableGeneration(after generation: TopologyGeneration) async -> TopologySnapshot {
        await system.awaitStableGeneration(after: generation)
    }
}

private actor GatedCheckpointStore: CheckpointStoring {
    let gate: PreflightGate?
    private var checkpoint: Checkpoint?
    init(gate: PreflightGate?) { self.gate = gate }
    func writeAtomic(_ checkpoint: Checkpoint) async throws {
        self.checkpoint = checkpoint
        await gate?.pause()
    }
    func restore(_ id: CheckpointID) async throws -> Checkpoint? { checkpoint?.id == id ? checkpoint : nil }
    func latest() async -> Checkpoint? { checkpoint }
}

private actor DisconnectSpy: LifecycleProvider {
    nonisolated let providerID = "deferred-test"
    nonisolated let isExperimental = false
    let system: SimulatedDisplaySystem
    private(set) var disconnects = 0
    init(system: SimulatedDisplaySystem) { self.system = system }
    func probe(_ environment: ProviderEnvironment) async -> ProviderProbe { await system.probe(environment) }
    func disconnect(_ target: DisplayRecordID, deadline: Date) async throws {
        disconnects += 1
        try await system.disconnect(target, deadline: deadline)
    }
    func reconnect(_ target: DisplayRecordID, deadline: Date) async throws { try await system.reconnect(target, deadline: deadline) }
    func recover(to checkpoint: Checkpoint) async throws { try await system.recover(to: checkpoint) }
}

final class DeferredDisconnectAdmissionTests: XCTestCase {
    func testNewReactionDuringEveryAsyncPreflightStageRefusesProviderDispatch() async throws {
        for stage in ["snapshot", "health", "checkpoint", "confirmation"] {
            let builtin = DisplayRecordID(rawValue: "builtin")
            let system = SimulatedDisplaySystem(observations: [
                DisplayObservation(recordID: builtin, isActive: true, isMain: true,
                                   displayClass: .builtIn, generation: .initial),
                DisplayObservation(recordID: .init(rawValue: "external"), isActive: true,
                                   displayClass: .external, generation: .initial)
            ])
            let gate = PreflightGate(), provider = DisconnectSpy(system: system)
            let coordinator = TopologyCoordinator(
                observer: GatedObserver(system: system, gate: stage == "snapshot" ? gate : nil),
                lifecycleProvider: provider,
                checkpoints: GatedCheckpointStore(gate: stage == "checkpoint" ? gate : nil),
                recoveryServiceHealthy: {
                    if stage == "health" { await gate.pause() }
                    return true
                },
                confirm: { _, _ in
                    if stage == "confirmation" { await gate.pause() }
                    return true
                })
            var reactions = ConfiguredReactionGeneration()
            let old = reactions.invalidate()
            let admission = reactions.admission(for: old)
            var arrival = AutoDisconnectBuiltInPolicy()
            arrival.observe(enabled: true, externalPresent: true, suppressed: false)
            let owed = try XCTUnwrap(arrival.pendingArrival)
            let operation = Task {
                try await coordinator.disconnect(builtin, options: .init(
                    actor: .system, identityConfidence: 1, isFirstUseForRoute: true,
                    authorization: admission))
            }
            while !(await gate.entered) { await Task.yield() }
            let latest = reactions.invalidate()
            await gate.release()
            let result = try await operation.value
            guard case .cancelled = result else { return XCTFail("\(stage): expected cancelled, got \(result)") }
            let dispatches = await provider.disconnects
            XCTAssertEqual(dispatches, 0, stage)
            let snapshot = await system.currentSnapshot()
            XCTAssertEqual(snapshot.observation(for: builtin)?.isActive, true, stage)
            XCTAssertFalse(reactions.isCurrent(old))
            XCTAssertTrue(reactions.admission(for: latest).isAuthorized)
            XCTAssertEqual(arrival.pendingArrival, owed, "refused preflight must leave arrival pending")
            arrival.consumeArrival(owed)
            XCTAssertNil(arrival.pendingArrival)
        }
    }

    func testOldArrivalCompletionCannotConsumeANewerArrival() throws {
        var arrival = AutoDisconnectBuiltInPolicy()
        arrival.observe(enabled: true, externalPresent: true, suppressed: false)
        let first = try XCTUnwrap(arrival.pendingArrival)
        arrival.observe(enabled: true, externalPresent: false, suppressed: false)
        arrival.observe(enabled: true, externalPresent: true, suppressed: false)
        let second = try XCTUnwrap(arrival.pendingArrival)
        arrival.consumeArrival(first)
        XCTAssertEqual(arrival.pendingArrival, second)
        arrival.consumeArrival(second)
        XCTAssertNil(arrival.pendingArrival)
    }
}
