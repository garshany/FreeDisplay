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

    func testACustomProfileOnAnyDisplayBlocks() {
        let blocking = ColorProfileGuard.blockingDisplays(
            readings: [.init(rawValue: "A"): .factory, .init(rawValue: "B"): .custom, .init(rawValue: "C"): .system],
            unreadable: [], previous: [])
        XCTAssertEqual(blocking, [.init(rawValue: "B")])
    }

    func testATransientReadFailureKeepsAKnownBlock() {
        let b = DisplayRecordID(rawValue: "B")
        XCTAssertEqual(ColorProfileGuard.blockingDisplays(readings: [.init(rawValue: "A"): .factory],
                                                          unreadable: [b], previous: [b]), [b])
        XCTAssertEqual(ColorProfileGuard.blockingDisplays(readings: [.init(rawValue: "A"): .factory],
                                                          unreadable: [b], previous: []), [],
                       "an unreadable display that wasn't blocking doesn't start blocking")
    }

    func testADisconnectedDisplayStopsBlocking() {
        XCTAssertEqual(ColorProfileGuard.blockingDisplays(readings: [.init(rawValue: "A"): .factory],
                                                          unreadable: [], previous: [.init(rawValue: "B")]), [])
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
