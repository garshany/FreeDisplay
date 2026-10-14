import XCTest
@testable import DisplayDomain

final class DisplayModeChoicesTests: XCTestCase {
    private func mode(buffer: Int = 2560, logical: Int = 2560, hz: Double = 75,
                      hidpi: Bool = false, depth: Int? = nil) -> DisplayMode {
        DisplayMode(pixelWidth: buffer, pixelHeight: buffer * 9 / 16,
                    pointWidth: logical, pointHeight: logical * 9 / 16,
                    refreshHz: hz, isHiDPI: hidpi, bitDepth: depth)
    }

    func testRetainsNonHiDPIAndHiDPIWithSameLogicalSize() {
        let current = mode()
        let hidpi = mode(buffer: 5120, hz: 60, hidpi: true)
        let choices = DisplayModeChoices.ordered(from: [current, hidpi, current], current: current)
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(choices.contains(current))
        XCTAssertTrue(choices.contains(hidpi))
        XCTAssertFalse(DisplayModeChoices.canApply(current, current: current, choices: choices))
        XCTAssertTrue(DisplayModeChoices.canApply(hidpi, current: current, choices: choices))
    }
    func testPreservesFractionalRefreshAndBitDepthVariants() {
        let variants = [mode(hz: 59.94), mode(hz: 60), mode(hz: 60, depth: 30)]
        XCTAssertEqual(DisplayModeChoices.ordered(from: variants, current: nil).count, 3)
        XCTAssertTrue(DisplayModeChoices.label(variants[0]).contains("59.94 Hz"))
        XCTAssertTrue(DisplayModeChoices.label(variants[2]).contains("30-bit"))
    }
    func testIncludesObservedCurrentModeWhenEnumerationOmitsItWithoutChoosingReplacement() {
        let current = mode()
        let other = mode(buffer: 5120, hz: 60, hidpi: true)
        let choices = DisplayModeChoices.ordered(from: [other], current: current)
        XCTAssertTrue(choices.contains(current))
        XCTAssertFalse(DisplayModeChoices.canApply(nil, current: current, choices: choices))
        XCTAssertFalse(DisplayModeChoices.canApply(current, current: current, choices: choices))
    }
    func testLabelsDiscloseLogicalAndFramebufferDimensionsWithoutNativeClaim() {
        let label = DisplayModeChoices.label(mode(buffer: 5120, hz: 60, hidpi: true))
        XCTAssertTrue(label.contains("2560 × 1440 pt"))
        XCTAssertTrue(label.contains("framebuffer 5120 × 2880 px"))
        XCTAssertTrue(label.contains("60 Hz · HiDPI"))
        XCTAssertFalse(label.lowercased().contains("native"))
        XCTAssertTrue(DisplayModeChoices.label(mode()).contains("no HiDPI"))
    }
    func testInvalidModesCannotBeOfferedOrApplied() {
        let invalid = [mode(buffer: 0), mode(logical: -1), mode(hz: .nan), mode(hz: .infinity), mode(hz: -60)]
        XCTAssertTrue(DisplayModeChoices.ordered(from: invalid, current: nil).isEmpty)
        for value in invalid {
            XCTAssertFalse(DisplayModeChoices.canApply(value, current: mode(), choices: [value]))
        }
    }
    func testUnreportedRefreshIsHonestAndAvailableListIsStable() {
        let unknown = mode(hz: 0)
        let known = mode()
        XCTAssertTrue(DisplayModeChoices.label(unknown).contains("refresh unknown"))
        XCTAssertEqual(DisplayModeChoices.ordered(from: [known, unknown], current: nil),
                       DisplayModeChoices.ordered(from: [unknown, known], current: nil))
    }
    func testExactMatchRejectsSilentFramebufferAndRefreshSubstitution() {
        let requested = mode(buffer: 5120, hz: 59.94, hidpi: true)
        XCTAssertTrue(DisplayModeChoices.matches(requested, requested: requested))
        XCTAssertFalse(DisplayModeChoices.matches(mode(buffer: 3840, hz: 59.94, hidpi: true), requested: requested))
        XCTAssertFalse(DisplayModeChoices.matches(mode(buffer: 5120, hz: 60, hidpi: true), requested: requested))
        XCTAssertFalse(DisplayModeChoices.matches(mode(buffer: 5120, logical: 1920, hz: 59.94, hidpi: true), requested: requested))
        XCTAssertFalse(DisplayModeChoices.matches(mode(buffer: 5120, hz: 59.94, hidpi: false), requested: requested))
    }
    func testBitDepthRequestIsNotSilentlyDropped() {
        XCTAssertFalse(DisplayModeChoices.matches(mode(depth: nil), requested: mode(depth: 30)))
        XCTAssertTrue(DisplayModeChoices.matches(mode(depth: 30), requested: mode(depth: 30)))
    }

    func testLowerDensityAlternativeHiddenByDefaultButCurrentAlwaysPreserved() {
        let low = mode(buffer: 1920, logical: 1920, hz: 60)
        let retina = mode(buffer: 3840, logical: 1920, hz: 60, hidpi: true)
        let current = mode()
        let visible = DisplayModeChoices.visible(from: [low, retina, current], current: current, includeLowerDensity: false)
        XCTAssertFalse(visible.contains(low))
        XCTAssertTrue(visible.contains(retina))
        XCTAssertTrue(visible.contains(current))
        XCTAssertTrue(DisplayModeChoices.visible(from: [low, retina], current: low, includeLowerDensity: false).contains(low))
    }
    func testExplicitAdditionalModesRevealsDensityAlternatives() {
        let low = mode(buffer: 1920, logical: 1920, hz: 60)
        let retina = mode(buffer: 3840, logical: 1920, hz: 60, hidpi: true)
        XCTAssertEqual(DisplayModeChoices.visible(from: [low, retina], current: nil, includeLowerDensity: true).count, 2)
    }
    func testUnpairedNonHiDPIModeIsNotInferredToBeLowResolution() {
        let native = mode()
        XCTAssertEqual(DisplayModeChoices.visible(from: [native], current: nil, includeLowerDensity: false), [native])
    }
    func testOnlyWarningFreeExactReadbackCanShowKeepConfirmation() {
        let requested = mode(buffer: 5120, hz: 60, hidpi: true)
        XCTAssertTrue(DisplayModeChoices.verifiedApply(warnings: [], actual: requested, requested: requested))
        XCTAssertFalse(DisplayModeChoices.verifiedApply(warnings: ["os rejected"], actual: requested, requested: requested))
        XCTAssertFalse(DisplayModeChoices.verifiedApply(warnings: [], actual: nil, requested: requested))
        XCTAssertFalse(DisplayModeChoices.verifiedApply(warnings: [], actual: mode(), requested: requested))
        XCTAssertFalse(DisplayModeChoices.verifiedApply(warnings: [], actual: mode(buffer: 5120, hz: 59.94, hidpi: true), requested: requested))
    }

    func testStaleUnofferedSelectionCannotBeApplied() {
        let current = mode()
        let stale = mode(buffer: 1920, logical: 1920, hz: 60)
        XCTAssertFalse(DisplayModeChoices.canApply(stale, current: current, choices: [current]))
    }
}
