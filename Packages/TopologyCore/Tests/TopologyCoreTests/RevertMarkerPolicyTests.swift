import XCTest
import DisplayDomain
@testable import TopologyCore

/// R1 P0: a rollback that didn't land must keep its recovery record (`revert.pending`).
final class RevertMarkerPolicyTests: XCTestCase {
    private let a = DisplayRecordID(rawValue: "a")
    private let b = DisplayRecordID(rawValue: "b")
    private let c = DisplayRecordID(rawValue: "c")
    private let good = DisplayMode(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080,
                                   refreshHz: 60, isHiDPI: true)
    private let bad = DisplayMode(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 3840, pointHeight: 2160,
                                  refreshHz: 30, isHiDPI: false)

    private func obs(_ id: DisplayRecordID, x: Int = 0, mode: DisplayMode? = nil,
                     mirrorOf: DisplayRecordID? = nil) -> DisplayObservation {
        DisplayObservation(recordID: id, isActive: true, origin: DisplayOrigin(x: x, y: 0), mode: mode,
                           mirrorSourceID: mirrorOf, generation: .initial)
    }

    // MARK: - Verifying a restore

    func testAnExactReadbackVerifies() {
        let wanted = [obs(a, mode: good), obs(b, x: 1920, mode: good)]
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: wanted, current: wanted), [])
        XCTAssertTrue(RevertMarkerPolicy.mayClearMarker(after: .restored(providerWarnings: [], mismatches: [])))
    }

    func testAModeMacOSKeptIsAMismatch() {
        let wanted = [obs(a, mode: good)]
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: wanted, current: [obs(a, mode: bad)]), [.mode(a)])
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: wanted, current: [obs(a)]), [.mode(a)],
                       "an unreadable mode isn't the recorded one")
    }

    func testAnOriginThatDidntMoveBackIsAMismatch() {
        let wanted = [obs(a), obs(b, x: 1920)]
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: wanted, current: [obs(a), obs(b, x: -1920)]),
                       [.origin(b)])
    }

    func testAMirrorSetThatStayedIsAMismatch() {
        let wanted = [obs(a), obs(b, x: 1920)]
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: wanted, current: [obs(a), obs(b, mirrorOf: a)]),
                       [.mirror(b)], "a mirror target's origin is its source's, so only the mirror counts")
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: [obs(a), obs(b, mirrorOf: a)],
                                                     current: [obs(a), obs(b, x: 1920)]),
                       [.mirror(b)], "an independent display that should mirror")
    }

    func testWhatCantBeRestoredIsntOwed() {
        // b is gone: nothing to judge for it, and the rest may have been re-packed.
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: [obs(a, x: 0, mode: good), obs(b, x: 1920)],
                                                     current: [obs(a, x: 100, mode: good)]), [])
        // c mirrored b, and b is gone: c can't mirror it again.
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: [obs(a), obs(c, mirrorOf: b)],
                                                     current: [obs(a), obs(c, x: 1920)]), [])
        // A new display re-packs the arrangement too: positions aren't held, modes still are.
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: [obs(a, mode: good)],
                                                     current: [obs(a, x: 1920, mode: bad), obs(c)]), [.mode(a)])
    }

    // MARK: - Keeping the record

    func testARejectedRestoreKeepsTheRecord() {
        XCTAssertFalse(RevertMarkerPolicy.mayClearMarker(after: .restored(providerWarnings: [],
                                                                         mismatches: [.mode(a)])))
        XCTAssertFalse(RevertMarkerPolicy.mayClearMarker(after: .restored(
            providerWarnings: ["no matching mode for 2"], mismatches: [])),
                       "a write the provider reported failing isn't trusted on readback alone")
    }

    func testKeepingTheSettingsReleasesTheRecord() {
        XCTAssertTrue(RevertMarkerPolicy.mayClearMarker(after: .kept))
        XCTAssertFalse(RevertMarkerPolicy.isVerified(.kept), "keeping restores nothing")
    }

    func testADisplayTurnedOffSinceIsLeftAlone() {
        // b was recorded independent; the user then turned it off, which the public provider does by
        // mirroring it onto main. Restoring the record must not switch it back on, nor wait for it.
        let recorded = [obs(a), obs(b, x: 1920)]
        let wanted = RevertMarkerPolicy.restorable(recorded, ledger: [b])
        XCTAssertEqual(wanted.map(\.recordID), [a])
        let after = RevertMarkerPolicy.restorable([obs(a), obs(b, mirrorOf: a)], ledger: [b])
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: wanted, current: after), [])
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: wanted,
                                                     current: RevertMarkerPolicy.restorable(
                                                        [obs(a, x: 50), obs(b, mirrorOf: a)], ledger: [b])),
                       [.origin(a)], "the rest is still judged in full")
    }
}
