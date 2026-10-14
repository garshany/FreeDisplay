import XCTest
import DisplayDomain
@testable import TopologyCore

/// SD-05: an entry kept after a failed reconnect (at quit, or from the menu) is owed ON — the wake
/// re-assert must never switch it back off, and seeing it lit is the end of it.
final class OwedReconnectWakeTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func obs(_ id: String, klass: DisplayClass = .external,
                     presence: PhysicalPresence?) -> DisplayObservation {
        DisplayObservation(recordID: DisplayRecordID(rawValue: id), cgDisplayID: 1, isActive: true,
                           displayClass: klass, physicalPresence: presence, generation: .initial)
    }

    private var builtIn: DisplayObservation { obs("builtin", klass: .builtIn, presence: .physical) }
    private var thirdParty: DisplayObservation { obs("displaylink", presence: .unverified) }

    private func offline(_ id: String, klass: DisplayClass = .builtIn, failedAt: Date? = nil) -> ManagedOfflineDisplay {
        ManagedOfflineDisplay(recordID: DisplayRecordID(rawValue: id), cgID: 9, name: id,
                              displayClass: klass, reconnectFailedAt: failedAt)
    }

    private func context(_ observations: [DisplayObservation], offline: [ManagedOfflineDisplay] = [],
                         wokeSecondsAgo: TimeInterval? = nil) -> WakeConvergencePolicy.Context {
        WakeConvergencePolicy.Context(now: epoch, observations: observations, managedOffline: offline,
                                      lastWakeAt: wokeSecondsAgo.map { epoch.addingTimeInterval(-$0) })
    }

    func testAFailedReconnectIsNeverPutBackOffAfterAWake() {
        let failed = offline("ext", klass: .external, failedAt: epoch.addingTimeInterval(-3600))
        let world = [builtIn, obs("ext", presence: .physical)]
        let waking = context(world, offline: [failed], wokeSecondsAgo: 2)
        XCTAssertTrue(WakeConvergencePolicy.entriesToStampRelit(waking).isEmpty)
        XCTAssertTrue(WakeConvergencePolicy.offlineIntent(waking).reassert.isEmpty)
        // Seeing it lit is what was owed: it is forgotten, wake window or not.
        XCTAssertEqual(WakeConvergencePolicy.entriesToForget(waking), [failed.recordID])
        XCTAssertEqual(WakeConvergencePolicy.entriesToForget(context(world, offline: [failed])), [failed.recordID])
    }

    func testAStillDarkFailedEntryStaysForTheNet() {
        let failed = offline("builtin", failedAt: epoch)
        XCTAssertTrue(WakeConvergencePolicy.entriesToForget(context([thirdParty], offline: [failed])).isEmpty)
        XCTAssertEqual(WakeConvergencePolicy.surfaceDecision(context([thirdParty], offline: [failed])),
                       .restore(failed))
    }
}

/// SD-05: quitting keeps every display the reconnect didn't actually bring back.
final class QuitReconnectLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ id: String, cgID: UInt32, relit: Bool = false) -> ManagedOfflineDisplay {
        ManagedOfflineDisplay(recordID: DisplayRecordID(rawValue: id), cgID: cgID, name: id,
                              displayClass: .external,
                              relitDuringWakeAt: relit ? Date(timeIntervalSince1970: 1) : nil)
    }

    private func lit(_ id: String, cgID: UInt32) -> DisplayObservation {
        DisplayObservation(recordID: DisplayRecordID(rawValue: id), cgDisplayID: cgID, isActive: true,
                           displayClass: .external, generation: .initial)
    }

    func testAReconnectThatProducedNoDisplayKeepsItsEntryStamped() {
        let kept = ReconnectVerification.ledgerAfterQuitReconnect(
            [entry("desk", cgID: 7, relit: true)], observations: [], at: now)
        XCTAssertEqual(kept.map(\.recordID.rawValue), ["desk"])
        XCTAssertEqual(kept.first?.reconnectFailedAt, now)
        XCTAssertNil(kept.first?.relitDuringWakeAt, "an entry owed ON must not carry an owed-off stamp")
    }

    func testOnlyTheDisplaysThatCameBackAreDropped() {
        let kept = ReconnectVerification.ledgerAfterQuitReconnect(
            [entry("back", cgID: 7), entry("stillDark", cgID: 8), entry("reminted", cgID: 9)],
            observations: [lit("back", cgID: 7), lit("cg:NEW-RECORD", cgID: 9)], at: now)
        XCTAssertEqual(kept.map(\.recordID.rawValue), ["stillDark"])
    }

    func testADisplayLitButStillInactiveIsNotBack() {
        var dark = lit("desk", cgID: 7)
        dark.isActive = false  // e.g. still mirrored by the public provider
        let kept = ReconnectVerification.ledgerAfterQuitReconnect([entry("desk", cgID: 7)],
                                                                  observations: [dark], at: now)
        XCTAssertEqual(kept.count, 1)
    }

    func testTheKeptLedgerRoundTripsThroughTheSharedStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("od-quit-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ManagedOfflineStore(directory: directory)
        let kept = ReconnectVerification.ledgerAfterQuitReconnect([entry("desk", cgID: 7)], observations: [], at: now)
        try store.save(kept)
        XCTAssertEqual(store.load(), kept)
    }
}
