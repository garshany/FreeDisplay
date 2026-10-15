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
        // b is gone: it is awaited, not judged, and the rest may have been re-packed.
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: [obs(a, x: 0, mode: good), obs(b, x: 1920)],
                                                     current: [obs(a, x: 100, mode: good)]), [.absent(b)])
        // c mirrored b, an unrecorded source that is gone: c can't mirror it again.
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: [obs(a), obs(c, mirrorOf: b)],
                                                     current: [obs(a), obs(c, x: 1920)]), [])
        // A new display re-packs the arrangement too: positions aren't held, modes still are.
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: [obs(a, mode: good)],
                                                     current: [obs(a, x: 1920, mode: bad), obs(c)]), [.mode(a)])
    }

    func testAReanchorWithWrongMainDisplayIsNotAVerifiedRestore() {
        var main = obs(a)
        main.isMain = true
        let wrong = obs(a)
        let mismatches = RevertMarkerPolicy.mismatches(wanted: [main], current: [wrong])
        XCTAssertFalse(mismatches.isEmpty)
        XCTAssertFalse(RevertMarkerPolicy.mayClearMarker(after: .restored(providerWarnings: [], mismatches: mismatches)))
    }

    // MARK: - Keeping the record

    func testARejectedRestoreKeepsTheRecord() {
        XCTAssertFalse(RevertMarkerPolicy.mayClearMarker(after: .restored(providerWarnings: [],
                                                                         mismatches: [.mode(a)])))
        XCTAssertFalse(RevertMarkerPolicy.mayClearMarker(after: .restored(
            providerWarnings: ["no matching mode for 2"], mismatches: [])),
                       "a write the provider reported failing isn't trusted on readback alone")
    }

    // MARK: - A recorded display that isn't connected (R4 P0)

    /// The finding: the display dropped out during a failed mode change, so the restore had no
    /// targets, no warnings and no mismatches — and the record was deleted as "restored".
    func testADisplayThatDroppedOutLeavesTheRestoreUnverifiedAndKeepsTheRecord() {
        let mismatches = RevertMarkerPolicy.mismatches(wanted: [obs(a, mode: good)], current: [])
        XCTAssertEqual(mismatches, [.absent(a)])
        let outcome = RevertMarkerPolicy.Outcome.restored(providerWarnings: [], mismatches: mismatches)
        XCTAssertFalse(RevertMarkerPolicy.isVerified(outcome))
        XCTAssertFalse(RevertMarkerPolicy.mayClearMarker(after: outcome))
        XCTAssertEqual(RevertMarkerPolicy.disposition(after: outcome), .awaitingDisplays([a]),
                       "not yet verified, which is reported as such rather than as a failed write")
    }

    /// Relaunching while the monitor is unplugged: the rest restores fine, the record still stays.
    func testARelaunchWithoutTheMonitorKeepsItsRecord() {
        let recorded = [obs(a, mode: good), obs(b, x: 1920, mode: good)]
        let outcome = RevertMarkerPolicy.Outcome.restored(
            providerWarnings: [], mismatches: RevertMarkerPolicy.mismatches(wanted: recorded, current: [obs(a, mode: good)]))
        XCTAssertEqual(RevertMarkerPolicy.disposition(after: outcome), .awaitingDisplays([b]))
        XCTAssertFalse(RevertMarkerPolicy.mayClearMarker(after: outcome))
        // Once it is back and shows as recorded, the record goes.
        let back = RevertMarkerPolicy.Outcome.restored(
            providerWarnings: [], mismatches: RevertMarkerPolicy.mismatches(wanted: recorded, current: recorded))
        XCTAssertEqual(RevertMarkerPolicy.disposition(after: back), .clear)
    }

    /// What stays on record while a display is awaited is what it is owed — not the connected
    /// displays' old settings, which would otherwise be put back at every launch over whatever was
    /// changed since.
    func testOnlyWhatTheAbsentDisplayIsOwedStaysOnRecord() {
        let recorded = [obs(a, mode: good), obs(b, x: 1920, mode: good), obs(c, mirrorOf: b)]
        let awaiting = RevertMarkerPolicy.Outcome.restored(
            providerWarnings: [],
            mismatches: RevertMarkerPolicy.mismatches(wanted: recorded, current: [obs(a, mode: good), obs(c)]))
        XCTAssertEqual(RevertMarkerPolicy.recordToKeep(recorded, after: awaiting), Array(recorded[1...]),
                       "b, and c's mirror of b, which couldn't be put back without it")
        XCTAssertEqual(RevertMarkerPolicy.recordToKeep(recorded, after: .restored(providerWarnings: [],
                                                                                  mismatches: [.mode(a), .absent(b)])),
                       recorded, "a failed restore keeps the whole record")
        XCTAssertNil(RevertMarkerPolicy.recordToKeep(recorded, after: .kept))
        // The next launch, b still away: the narrowed record is awaited as it is.
        let narrowed = [obs(b, x: 1920, mode: good), obs(c, mirrorOf: b)]
        let again = RevertMarkerPolicy.Outcome.restored(
            providerWarnings: [], mismatches: RevertMarkerPolicy.mismatches(wanted: narrowed, current: [obs(a), obs(c)]))
        XCTAssertEqual(RevertMarkerPolicy.recordToKeep(narrowed, after: again), narrowed)
    }

    /// Final review: B mirrors A, B is away, so only B stayed on record. A later launch with B back
    /// and A away then had no `.absent(A)` to wait on — the mirror check skips a missing source — and
    /// cleared the record without ever putting B's mirror of A back. The source stays with its mirror.
    func testAKeptMirrorKeepsItsRecordedSource() {
        let recorded = [obs(a, mode: good), obs(b, mirrorOf: a), obs(c, x: 1920, mode: good)]
        let bAway = RevertMarkerPolicy.Outcome.restored(
            providerWarnings: [],
            mismatches: RevertMarkerPolicy.mismatches(wanted: recorded,
                                                      current: [obs(a, mode: good), obs(c, x: 1920, mode: good)]))
        let narrowed = RevertMarkerPolicy.recordToKeep(recorded, after: bAway)
        XCTAssertEqual(narrowed?.map(\.recordID), [a, b], "a stays as b's mirror source; c goes")
        // The next launch: b is back, a is away — the record is still awaited, not cleared.
        let aAway = RevertMarkerPolicy.Outcome.restored(
            providerWarnings: [],
            mismatches: RevertMarkerPolicy.mismatches(wanted: narrowed ?? [], current: [obs(b)]))
        XCTAssertFalse(RevertMarkerPolicy.mayClearMarker(after: aAway))
    }

    /// OpenDisplay's own virtual screens come back under a new identity every launch, if at all.
    func testAWindowServerOnlyScreenIsNeverAwaited() {
        var virtualScreen = obs(b, x: 1920)
        virtualScreen.physicalPresence = .virtual
        var placeholder = obs(c)
        placeholder.displayClass = .virtual
        let mismatches = RevertMarkerPolicy.mismatches(wanted: [obs(a, mode: good), virtualScreen, placeholder],
                                                       current: [obs(a, mode: good)])
        XCTAssertEqual(mismatches, [])
        XCTAssertTrue(RevertMarkerPolicy.mayClearMarker(after: .restored(providerWarnings: [], mismatches: mismatches)))
        var unverified = obs(b)
        unverified.physicalPresence = .unverified
        XCTAssertEqual(RevertMarkerPolicy.mismatches(wanted: [unverified], current: []), [.absent(b)],
                       "a screen without hardware evidence may be a real monitor: still awaited")
    }

    func testAnAbsentDisplayNeverMasksARealFailure() {
        XCTAssertEqual(RevertMarkerPolicy.disposition(after: .restored(providerWarnings: [],
                                                                       mismatches: [.absent(b), .mode(a)])),
                       .unverified)
        XCTAssertEqual(RevertMarkerPolicy.disposition(after: .restored(providerWarnings: ["no matching mode for 2"],
                                                                       mismatches: [.absent(b)])),
                       .unverified)
    }

    func testKeepingTheSettingsReleasesTheRecord() {
        XCTAssertTrue(RevertMarkerPolicy.mayClearMarker(after: .kept))
        XCTAssertEqual(RevertMarkerPolicy.disposition(after: .kept), .clear)
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
