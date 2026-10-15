import XCTest
import DisplayDomain
import ProviderInterfaces
import SimulatorProvider
@testable import TopologyCore

/// Reconnect All for a surface with no app model: it must work from the persisted ledger. The
/// gateway it replaces asked the provider snapshot, which never lists what the app turned off.
final class ManagedOfflineRecoveryTests: XCTestCase {
    private let desk = DisplayRecordID(rawValue: "cg:desk")
    private let gone = DisplayRecordID(rawValue: "cg:gone")
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func entry(_ id: DisplayRecordID, relit: Date? = nil) -> ManagedOfflineDisplay {
        ManagedOfflineDisplay(recordID: id, cgID: 0, name: id.rawValue, displayClass: .external,
                              relitDuringWakeAt: relit)
    }

    /// Collects every ledger the run saves, in order.
    private final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var ledgers: [[ManagedOfflineDisplay]] = []
        func append(_ ledger: [ManagedOfflineDisplay]) { lock.withLock { ledgers.append(ledger) } }
        var all: [[ManagedOfflineDisplay]] { lock.withLock { ledgers } }
    }

    func testLedgerAfterEachOutcome() {
        let ledger = [entry(desk, relit: now), entry(gone)]
        XCTAssertEqual(ManagedOfflineRecovery.ledger(ledger, after: .lit, on: ledger[0], at: now), [entry(gone)])
        var stamped = entry(desk, relit: now)
        stamped.reconnectFailedAt = now
        XCTAssertEqual(ManagedOfflineRecovery.ledger(ledger, after: .notLit, on: ledger[0], at: now),
                       [stamped, entry(gone)], "kept, stamped — the only record the display exists")
        XCTAssertEqual(ManagedOfflineRecovery.ledger(ledger, after: .rejected("no"), on: ledger[0], at: now), ledger)
    }

    /// The finding: with no model, the intent's gateway saw an empty offline list and reported
    /// "nothing to reconnect". From the ledger, the turned-off display is reconnected and verified.
    func testReconnectsWhatTheLedgerHoldsAndSavesAfterEachDisplay() async {
        let system = SimulatedDisplaySystem(observations: [
            DisplayObservation(recordID: desk, isActive: false, origin: .zero, rotation: .degrees0,
                               isMain: false, generation: .initial)
        ])
        let gatewaySees = await CommandGateway(observer: system, lifecycleProvider: system,
                                               checkpoints: InMemoryCheckpointStore()).reconnectAll()
        XCTAssertEqual(gatewaySees.status, .noOp, "the provider snapshot knows nothing the app turned off")

        let saved = Saved()
        let results = await ManagedOfflineRecovery.reconnectAll(
            ledger: [entry(desk), entry(gone)],
            attempt: { offline in
                // Record-id entries (no display number): the ledger can't contradict them.
                await ManagedOfflineRecovery.verifiedAttempt(offline, lifecycle: system, observer: system,
                                                             ledger: [], uuidForDisplayNumber: { _ in nil },
                                                             deadline: .distantFuture, escalate: {})
            },
            save: { saved.append($0) })

        XCTAssertEqual(results.map(\.displayId), [desk.rawValue, gone.rawValue])
        XCTAssertEqual(results.map(\.reconnected), [true, false])
        XCTAssertEqual(saved.all, [[entry(gone)], [entry(gone)]], "saved after each display; the refused one kept")
        let lit = await system.currentSnapshot().observations.first { $0.recordID == desk }?.isActive
        XCTAssertEqual(lit, true)
    }

    func testAnEmptyLedgerIsNothingToReconnect() async {
        let saved = Saved()
        let results = await ManagedOfflineRecovery.reconnectAll(
            ledger: [], attempt: { _ in .lit }, save: { saved.append($0) })
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(saved.all.isEmpty)
    }
}
