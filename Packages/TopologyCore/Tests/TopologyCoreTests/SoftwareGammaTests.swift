import XCTest
import DisplayDomain
@testable import TopologyCore

final class SoftwareGammaTests: XCTestCase {
    private let warm = ColorTemperatureCurve.gains(kelvin: 4000)

    // MARK: - GammaSlotPolicy

    func testNothingNeedsGammaMeansNoColourTableCall() {
        XCTAssertFalse(GammaSlotPolicy.needsGamma(dim: 1, gains: .neutral, boost: 1))
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: false, owned: false, blocked: false), .none)
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: false, owned: false, blocked: true), .none)
    }

    func testOverlayOnlyDimmingNeverNeedsGamma() {
        // FB-04: the overlay method's split leaves gamma untouched, so with neutral warmth and no
        // boost there is nothing to write — not even an identity formula.
        for level: Float in [1, 0.6, 0.2, 0] {
            let split = DimmingComposer.split(method: .overlay, level: level)
            XCTAssertFalse(GammaSlotPolicy.needsGamma(dim: split.gammaLevel, gains: .neutral, boost: 1))
        }
    }

    func testAnyDimWarmthOrBoostNeedsGamma() {
        XCTAssertTrue(GammaSlotPolicy.needsGamma(dim: 0.5, gains: .neutral, boost: 1))
        XCTAssertTrue(GammaSlotPolicy.needsGamma(dim: 1, gains: warm, boost: 1))
        XCTAssertTrue(GammaSlotPolicy.needsGamma(dim: 1, gains: .neutral, boost: 1.5))
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: true, owned: false, blocked: false), .write)
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: true, owned: true, blocked: false), .write)
    }

    func testReturningToNeutralHandsTheSlotBackToColorSync() {
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: false, owned: true, blocked: false), .release)
    }

    func testABlockedGammaWritesNothingAndReleasesAnInstalledTable() {
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: true, owned: false, blocked: true), .blocked)
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: true, owned: true, blocked: true), .release)
    }

    func testBlockedGammaFallsBackToTheOverlay() {
        for method in DimmingMethod.allCases {
            XCTAssertEqual(GammaSlotPolicy.effectiveMethod(method, gammaBlocked: true), .overlay)
            XCTAssertEqual(GammaSlotPolicy.effectiveMethod(method, gammaBlocked: false), method)
        }
    }

    // MARK: - ColorProfileGuard

    func testProfileClassification() {
        let factory = "/Library/ColorSync/Profiles/Displays/LG HDR WQHD-1A2B.icc"
        XCTAssertEqual(ColorProfileGuard.classify(assignedPath: nil, factoryPaths: [factory]), .factory)
        XCTAssertEqual(ColorProfileGuard.classify(assignedPath: factory, factoryPaths: [factory]), .factory)
        XCTAssertEqual(ColorProfileGuard.classify(
            assignedPath: "/Library/ColorSync/Profiles/Displays/Other display-9F.icc", factoryPaths: [factory]),
                       .factory, "another display's generated factory profile")
        XCTAssertEqual(ColorProfileGuard.classify(
            assignedPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc", factoryPaths: []), .system)
        XCTAssertEqual(ColorProfileGuard.classify(
            assignedPath: "/Users/me/Library/ColorSync/Profiles/Calibrated.icc", factoryPaths: []), .custom)
        XCTAssertEqual(ColorProfileGuard.classify(
            assignedPath: "/Library/ColorSync/Profiles/Shared custom.icc", factoryPaths: []), .custom)
        XCTAssertEqual(ColorProfileGuard.classify(
            assignedPath: "/Users/me/Library/ColorSync/Profiles/Displays/Calibrated.icc", factoryPaths: []),
                       .custom, "the user's own Displays folder is not the factory folder")
    }

    private let a = DisplayRecordID(rawValue: "A")
    private let b = DisplayRecordID(rawValue: "B")
    private let c = DisplayRecordID(rawValue: "C")

    /// The guard's verdict after one round of reads.
    private func blocking(connected: Set<DisplayRecordID>, readings: [DisplayRecordID: ColorProfileGuard.Assignment],
                          previous: [DisplayRecordID: ColorProfileGuard.Knowledge] = [:]) -> Set<DisplayRecordID> {
        ColorProfileGuard.blockingDisplays(
            ColorProfileGuard.knowledge(connected: connected, readings: readings, previous: previous))
    }

    func testCustomAndUnknownAssignmentsBlockOnlyTheirOwnDisplay() {
        let knowledge: [DisplayRecordID: ColorProfileGuard.Knowledge] = [
            a: .verified(.factory), b: .verified(.custom), c: .unverified
        ]
        XCTAssertFalse(ColorProfileGuard.blocksGamma(for: a, knowledge: knowledge, allowGammaWithCustomProfiles: false))
        XCTAssertTrue(ColorProfileGuard.blocksGamma(for: b, knowledge: knowledge, allowGammaWithCustomProfiles: false))
        XCTAssertTrue(ColorProfileGuard.blocksGamma(for: c, knowledge: knowledge, allowGammaWithCustomProfiles: false))
    }

    func testPendingFirstReadFailsClosedAndOverrideAllowsEveryAssignment() {
        XCTAssertTrue(ColorProfileGuard.blocksGamma(for: a, knowledge: [:], allowGammaWithCustomProfiles: false))
        for knowledge: ColorProfileGuard.Knowledge in [.verified(.factory), .verified(.system), .verified(.custom), .unverified] {
            XCTAssertFalse(ColorProfileGuard.blocksGamma(for: a, knowledge: [a: knowledge], allowGammaWithCustomProfiles: true))
        }
        XCTAssertFalse(ColorProfileGuard.blocksGamma(for: a, knowledge: [:], allowGammaWithCustomProfiles: true))
    }

    func testUnaffectedDisplayKeepsEverySoftwareGammaAdjustment() {
        let knowledge: [DisplayRecordID: ColorProfileGuard.Knowledge] = [
            a: .verified(.system), b: .verified(.custom)
        ]
        let transfers = [SoftwareImageTransfer(dim: 0.5), SoftwareImageTransfer(dim: 1, gains: warm),
                         SoftwareImageTransfer(dim: 1, contrast: 1.3), SoftwareImageTransfer(dim: 1, boost: 1.5)]
        for transfer in transfers {
            for (id, expected) in [(a, GammaSlotPolicy.Action.write), (b, .blocked)] {
                let blocked = ColorProfileGuard.blocksGamma(for: id, knowledge: knowledge,
                                                            allowGammaWithCustomProfiles: false)
                XCTAssertEqual(GammaSlotPolicy.action(needsGamma: transfer.needsGamma, owned: false, blocked: blocked), expected)
            }
        }
    }

    func testPendingSeedAndChangingBlockMembershipPreservePerDisplayVerdicts() {
        var knowledge = ColorProfileGuard.knowledge(connected: [a, b, c], readings: [a: .factory, b: .custom], previous: [:])
        XCTAssertEqual(ColorProfileGuard.blockingDisplays(knowledge), [b, c])
        // A refresh's empty-read seed must preserve verified assignments and pending C separately.
        knowledge = ColorProfileGuard.knowledge(connected: [a, b, c], readings: [:], previous: knowledge)
        XCTAssertFalse(ColorProfileGuard.blocksGamma(for: a, knowledge: knowledge, allowGammaWithCustomProfiles: false))
        XCTAssertTrue(ColorProfileGuard.blocksGamma(for: c, knowledge: knowledge, allowGammaWithCustomProfiles: false))
        let before = ColorProfileGuard.blockingDisplays(knowledge)
        knowledge = ColorProfileGuard.knowledge(connected: [a, b, c], readings: [a: .custom, b: .factory], previous: knowledge)
        XCTAssertEqual(before.symmetricDifference(ColorProfileGuard.blockingDisplays(knowledge)), [a, b],
                       "a nonempty global guard is insufficient to detect these two changed displays")
    }

    func testCustomProfileIdentifiesOnlyItsOwnDisplay() {
        XCTAssertEqual(blocking(connected: [a, b, c], readings: [a: .factory, b: .custom, c: .system]), [b])
    }

    func testAnAssignmentThatWasNeverReadBlocks() {
        // R1 P1: the first ColorSync read of a custom-profile display fails — it used to contribute
        // no block, so gamma went on being written next to the custom profile.
        let knowledge = ColorProfileGuard.knowledge(connected: [a, b], readings: [a: .factory], previous: [:])
        XCTAssertEqual(knowledge[b], .unverified)
        XCTAssertEqual(ColorProfileGuard.blockingDisplays(knowledge), [b])
        XCTAssertEqual(ColorProfileGuard.unverifiedDisplays(knowledge), [b])
    }

    func testADisplayThatArrivedAfterTheReadBeganIsPendingAndBlocks() {
        XCTAssertEqual(blocking(connected: [a, b], readings: [a: .factory]), [b])
    }

    func testTheBlockLiftsOnceTheAssignmentIsVerified() {
        let pending = ColorProfileGuard.knowledge(connected: [a], readings: [:], previous: [:])
        XCTAssertEqual(ColorProfileGuard.blockingDisplays(pending), [a])
        XCTAssertEqual(blocking(connected: [a], readings: [a: .factory], previous: pending), [])
    }

    func testATransientReadFailureKeepsWhatWasVerified() {
        XCTAssertEqual(blocking(connected: [a, b], readings: [a: .factory], previous: [b: .verified(.custom)]), [b],
                       "a known block survives a failed re-read")
        XCTAssertEqual(blocking(connected: [a, b], readings: [a: .factory], previous: [b: .verified(.factory)]), [],
                       "a verified factory assignment survives a failed re-read too")
        XCTAssertEqual(blocking(connected: [a, b], readings: [a: .factory], previous: [b: .unverified]), [b],
                       "still never read: still blocking")
    }

    func testADisconnectedDisplayStopsBlockingAndIsVerifiedAfreshWhenItReturns() {
        let gone = ColorProfileGuard.knowledge(connected: [a], readings: [a: .factory], previous: [b: .verified(.custom)])
        XCTAssertNil(gone[b])
        XCTAssertEqual(ColorProfileGuard.blockingDisplays(gone), [])
        XCTAssertEqual(blocking(connected: [a, b], readings: [a: .factory],
                                previous: ColorProfileGuard.knowledge(connected: [a], readings: [:],
                                                                      previous: [b: .verified(.factory)])),
                       [b], "a returning display's old verdict was dropped while it was away")
    }

    // MARK: - Written displays and restore selection

    func testRestoreSelectsOnlySuccessfullyWrittenDisplay() {
        var tracker = GammaWriteTracker()
        XCTAssertNil(tracker.displayToRestore(for: a, currentDisplayID: 1), "safe startup owns no tables")
        tracker.recordWrite(for: a, displayID: 1, succeeded: true)
        tracker.recordWrite(for: b, displayID: 2, succeeded: false)
        XCTAssertEqual(tracker.displayToRestore(for: a, currentDisplayID: 1), 1)
        XCTAssertNil(tracker.displayToRestore(for: b, currentDisplayID: 2))
        XCTAssertNil(tracker.displayToRestore(for: c, currentDisplayID: 3), "another app's display is untouched")
    }

    func testRestoringOneDisplayLeavesTheOtherOwnedAndFailedRestoreCanRetry() {
        var tracker = GammaWriteTracker()
        tracker.recordWrite(for: a, displayID: 1, succeeded: true)
        tracker.recordWrite(for: b, displayID: 2, succeeded: true)
        tracker.recordWrite(for: a, displayID: 1, succeeded: false)
        tracker.recordRestore(for: a, succeeded: false)
        XCTAssertEqual(tracker.displayToRestore(for: a, currentDisplayID: 1), 1)
        tracker.recordRestore(for: a, succeeded: true)
        XCTAssertNil(tracker.displayToRestore(for: a, currentDisplayID: 1), "quit after cleanup does not reset twice")
        XCTAssertEqual(tracker.displayToRestore(for: b, currentDisplayID: 2), 2)
    }

    func testDepartureOrChangedDisplayNumberCannotResetAnotherSurface() {
        var tracker = GammaWriteTracker()
        tracker.recordWrite(for: a, displayID: 1, succeeded: true)
        tracker.recordWrite(for: b, displayID: 2, succeeded: true)
        XCTAssertNil(tracker.displayToRestore(for: a, currentDisplayID: nil))
        XCTAssertNil(tracker.displayToRestore(for: a, currentDisplayID: 3))
        tracker.retainConnected([a: 3, c: 2])
        XCTAssertFalse(tracker.contains(a))
        XCTAssertFalse(tracker.contains(b))
        XCTAssertNil(tracker.displayToRestore(for: c, currentDisplayID: 2))
        tracker.retainConnected([a: 1])
        XCTAssertNil(tracker.displayToRestore(for: a, currentDisplayID: 1), "return requires a new successful write")
    }

    // MARK: - Software brightness floor (TR-02)

    func testSoftwareBrightnessReportsTheFlooredLevelItApplies() {
        XCTAssertEqual(DimmingComposer.softwareBrightnessLevel(requested: 0), DimmingComposer.gammaFloor)
        XCTAssertEqual(DimmingComposer.softwareBrightnessLevel(requested: 0.10), DimmingComposer.gammaFloor)
        XCTAssertEqual(DimmingComposer.softwareBrightnessLevel(requested: 0.5), 0.5)
        XCTAssertEqual(DimmingComposer.softwareBrightnessLevel(requested: 1.2), 1)
    }

    func testKeyStepsDoNotAccumulateBelowTheFloor() {
        // A key press steps from the cached level; caching the applied level keeps every step
        // below the floor at the floor, and the first step up leaves it at once.
        var level: Float = 0.2
        for _ in 0..<5 { level = DimmingComposer.softwareBrightnessLevel(requested: level - 0.0625) }
        XCTAssertEqual(level, DimmingComposer.gammaFloor)
        level = DimmingComposer.softwareBrightnessLevel(requested: level + 0.0625)
        XCTAssertEqual(level, DimmingComposer.gammaFloor + 0.0625, accuracy: 0.0001)
    }
}
