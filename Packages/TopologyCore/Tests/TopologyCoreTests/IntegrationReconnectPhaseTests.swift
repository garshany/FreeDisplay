import XCTest
import DisplayDomain
import SimulatorProvider
@testable import TopologyCore

final class IntegrationReconnectPhaseTests: XCTestCase {
    func testSoftReconnectCallbackRunsBeforeProviderAndAfterIdentityResolution() async throws {
        let id = DisplayRecordID(rawValue: "cg:desk")
        let system = SimulatedDisplaySystem(observations: [DisplayObservation(recordID: id, isActive: false, generation: .initial)])
        let capture = IntegrationPhaseCapture()
        let entry = ManagedOfflineDisplay(recordID: id, cgID: 0, name: "Desk", displayClass: .external)
        try await ManagedOfflineRecovery.requestReconnect(entry, lifecycle: system,
            observations: await system.currentSnapshot().observations, ledger: [], uuidForDisplayNumber: { _ in nil }, deadline: .distantFuture,
            beforeRequest: {
                let active = await system.currentSnapshot().observations.first?.isActive
                await capture.append(active == false)
            })
        let captures = await capture.values
        XCTAssertEqual(captures, [true])
        let snapshot = await system.currentSnapshot()
        XCTAssertEqual(snapshot.observations.first?.isActive, true)
    }
    func testCoordinatorSnapshotReconnectAlsoEmitsBeforeProvider() async {
        let id = DisplayRecordID(rawValue: "desk")
        let record = ManagedOfflineRecord(displayID: id, actor: .ui, reason: "test", providerID: "simulator.lifecycle.v1")
        let system = SimulatedDisplaySystem(observations: [DisplayObservation(recordID: id, isActive: false, generation: .initial)], managedOffline: [record])
        let coordinator = TopologyCoordinator(observer: system, lifecycleProvider: system, checkpoints: InMemoryCheckpointStore(), recoveryServiceHealthy: { true }, confirm: { _, _ in true })
        let capture = IntegrationPhaseCapture()
        let results = await coordinator.reconnectAll(beforeRequest: { target in
            let snapshot = await system.currentSnapshot()
            await capture.append(target == id && snapshot.observations.first?.isActive == false)
        })
        let captures = await capture.values
        XCTAssertEqual(captures, [true]); XCTAssertEqual(results[id], true)
    }
    func testRefusedIdentityNeverEmitsSoftReconnect() async {
        let id = DisplayRecordID(rawValue: "cg:desk")
        let system = SimulatedDisplaySystem(observations: [])
        let capture = IntegrationPhaseCapture()
        let entry = ManagedOfflineDisplay(recordID: id, cgID: 7, name: "Desk", displayClass: .external)
        do {
            try await ManagedOfflineRecovery.requestReconnect(entry, lifecycle: system, observations: [], ledger: [entry],
                uuidForDisplayNumber: { _ in "different-display" }, deadline: .distantFuture,
                beforeRequest: { await capture.append(true) })
            XCTFail("Identity must refuse")
        } catch {}
        let captures = await capture.values
        XCTAssertTrue(captures.isEmpty)
    }
}
private actor IntegrationPhaseCapture {
    var values: [Bool] = []
    func append(_ value: Bool) { values.append(value) }
}
