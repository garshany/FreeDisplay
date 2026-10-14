import XCTest
@testable import TopologyCore

/// TR-14/IN-17/AM-18: software contrast composed into the one gamma transfer with dim, warmth and
/// XDR boost, and the suspension that bypasses the image adjustments while brightness keeps working.
final class SoftwareImageTransferTests: XCTestCase {
    private let warm = ColorTemperatureCurve.gains(kelvin: 4000)
    private let count = 256

    /// The table the provider wrote before contrast existed — `min(1, (i/255 × boost) × scale × gain)`
    /// with the 0.15 floor on the dim — kept here as the reference the composition must not drift from.
    private func originalTable(dim: Float, gain: Float, boost: Float) -> [Float] {
        let scale = max(0.15, min(1, dim))
        let r = scale * min(max(gain, 0), 1)
        return (0..<count).map { i in
            let input = Float(i) / Float(count - 1) * boost
            return min(1, input * r)
        }
    }

    // MARK: - Neutral contrast leaves the existing paths exactly as they were

    func testNeutralContrastIsAnExactIdentity() {
        for i in 0..<count {
            let x = Float(i) / Float(count - 1)
            XCTAssertEqual(SoftwareContrast.apply(x, factor: SoftwareContrast.neutral), x)
        }
    }

    func testWithoutContrastOrBoostTheFormulaPathAndItsCoefficientsAreUnchanged() {
        for dim: Float in [1, 0.6, 0.15, 0.05, 0] {
            let transfer = SoftwareImageTransfer(dim: dim, gains: warm)
            XCTAssertFalse(transfer.needsTable, "no curve and no boost: the formula is enough")
            let scale = max(0.15, min(1, dim))
            XCTAssertEqual(transfer.channelScales.red, scale * warm.red)
            XCTAssertEqual(transfer.channelScales.green, scale * warm.green)
            XCTAssertEqual(transfer.channelScales.blue, scale * warm.blue)
        }
    }

    func testANeutralContrastBoostTableIsBitIdenticalToTheOriginalOne() {
        for (dim, boost) in [(Float(1), Float(1.6)), (0.6, 2.4), (0.1, 1.2)] {
            let tables = SoftwareImageTransfer(dim: dim, gains: warm, boost: boost).tables(count: count)
            XCTAssertEqual(tables.red, originalTable(dim: dim, gain: warm.red, boost: boost))
            XCTAssertEqual(tables.green, originalTable(dim: dim, gain: warm.green, boost: boost))
            XCTAssertEqual(tables.blue, originalTable(dim: dim, gain: warm.blue, boost: boost))
        }
    }

    // MARK: - Contrast curve

    func testContrastPivotsAroundMidGrey() {
        for factor: Float in [0.5, 0.8, 1.2, 1.5] {
            XCTAssertEqual(SoftwareContrast.apply(0.5, factor: factor), 0.5, accuracy: 0.0001)
        }
        // Lower contrast lifts black and pulls white in; higher contrast clips both ends.
        XCTAssertEqual(SoftwareContrast.apply(0, factor: 0.5), 0.25, accuracy: 0.0001)
        XCTAssertEqual(SoftwareContrast.apply(1, factor: 0.5), 0.75, accuracy: 0.0001)
        XCTAssertEqual(SoftwareContrast.apply(0.1, factor: 1.5), 0)
        XCTAssertEqual(SoftwareContrast.apply(0.9, factor: 1.5), 1)
        XCTAssertEqual(SoftwareContrast.apply(0.25, factor: 1.5), 0.125, accuracy: 0.0001)
    }

    func testTheClippedShareIsWhatTheCurveActuallyClips() {
        XCTAssertEqual(SoftwareContrast.clippedShare(factor: 1), 0)
        XCTAssertEqual(SoftwareContrast.clippedShare(factor: 0.7), 0, "lowered contrast clips nothing")
        let factor: Float = 1.5
        let share = SoftwareContrast.clippedShare(factor: factor)
        XCTAssertEqual(share, 1.0 / 3.0, accuracy: 0.0001)
        // Count the inputs the curve sends to exactly 0 or 1 on a fine ramp.
        let samples = 10_000
        let clipped = (0...samples).filter { i in
            let out = SoftwareContrast.apply(Float(i) / Float(samples), factor: factor)
            return out == 0 || out == 1
        }.count
        XCTAssertEqual(Float(clipped) / Float(samples + 1), share, accuracy: 0.001)
    }

    func testTheStoredFactorIsAWholePercentInsideTheControlAndNeutralIsNil() {
        XCTAssertNil(SoftwareContrast.normalized(1))
        XCTAssertNil(SoftwareContrast.normalized(1.004), "a drag landing on 100% is neutral")
        XCTAssertEqual(SoftwareContrast.normalized(1.2), 1.2)
        XCTAssertEqual(SoftwareContrast.normalized(1.234), 1.23)
        XCTAssertEqual(SoftwareContrast.normalized(0.1), SoftwareContrast.minimum)
        XCTAssertEqual(SoftwareContrast.normalized(9), SoftwareContrast.maximum)
    }

    func testTheTraySliderPutsNeutralInTheMiddle() {
        XCTAssertEqual(SoftwareContrast.position(forFactor: SoftwareContrast.neutral), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SoftwareContrast.factor(forPosition: 0), SoftwareContrast.minimum)
        XCTAssertEqual(SoftwareContrast.factor(forPosition: 1), SoftwareContrast.maximum)
        for position: Float in [0, 0.25, 0.5, 0.8, 1] {
            let factor = SoftwareContrast.factor(forPosition: position)
            XCTAssertEqual(SoftwareContrast.position(forFactor: factor), position, accuracy: 0.0001)
        }
    }

    // MARK: - Composition

    func testContrastAloneNeedsGammaAndATable() {
        let transfer = SoftwareImageTransfer(dim: 1, contrast: 1.2)
        XCTAssertTrue(transfer.needsGamma)
        XCTAssertTrue(transfer.needsTable, "the formula can't clip")
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: transfer.needsGamma, owned: false, blocked: false), .write)
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: transfer.needsGamma, owned: false, blocked: true), .blocked,
                       "the custom-profile safeguard blocks contrast like any other table")
    }

    func testOverlayDimmingWithNeutralContrastStillNeedsNoGamma() {
        // FB-04 stays true: the overlay split's untouched gamma plus neutral warmth and contrast is
        // the display's own calibration, so nothing is written.
        let split = DimmingComposer.split(method: .overlay, level: 0.3)
        let transfer = SoftwareImageTransfer(dim: split.gammaLevel)
        XCTAssertFalse(transfer.needsGamma)
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: transfer.needsGamma, owned: false, blocked: false), .none)
    }

    func testChangingWarmthKeepsTheContrastCurveAndTheDim() {
        let neutral = SoftwareImageTransfer(dim: 0.6, contrast: 1.3).tables(count: count)
        let tinted = SoftwareImageTransfer(dim: 0.6, gains: warm, contrast: 1.3).tables(count: count)
        // The dominant (red) channel is pinned at gain 1, so it is the untinted curve exactly…
        XCTAssertEqual(tinted.red, neutral.red)
        // …and every other channel is the same curve scaled by its own gain.
        for i in 0..<count {
            XCTAssertEqual(tinted.blue[i], neutral.blue[i] * warm.blue, accuracy: 0.0001)
        }
    }

    func testChangingContrastKeepsTheWarmthAndTheDim() {
        let flat = SoftwareImageTransfer(dim: 0.6, gains: warm)
        let curved = SoftwareImageTransfer(dim: 0.6, gains: warm, contrast: 1.3)
        XCTAssertEqual(curved.channelScales.red, flat.channelScales.red)
        XCTAssertEqual(curved.channelScales.blue, flat.channelScales.blue)
        // Mid-grey is the pivot, so it lands exactly where the uncurved transfer puts it.
        let mid = curved.tables(count: 3)
        let flatMid = flat.tables(count: 3)
        XCTAssertEqual(mid.red[1], flatMid.red[1], accuracy: 0.0001)
        XCTAssertEqual(mid.blue[1], flatMid.blue[1], accuracy: 0.0001)
    }

    func testBoostAndContrastCompose() {
        let transfer = SoftwareImageTransfer(dim: 1, contrast: 0.8, boost: 2)
        let tables = transfer.tables(count: count)
        for i in 0..<count {
            let x = Float(i) / Float(count - 1)
            XCTAssertEqual(tables.red[i], min(1, SoftwareContrast.apply(x, factor: 0.8) * 2), accuracy: 0.0001)
        }
    }

    func testTheGammaFloorStillBoundsTheBrightestOutputWhenContrastIsLowered() {
        for dim: Float in [0, 0.05, 0.15, 0.3, 0.6, 1] {
            for factor: Float in [0.5, 0.75, 1, 1.25, 1.5] {
                let transfer = SoftwareImageTransfer(dim: dim, contrast: factor)
                let white = transfer.tables(count: count).red.max() ?? 0
                XCTAssertGreaterThanOrEqual(white, DimmingComposer.gammaFloor - 0.0001,
                                            "dim \(dim), contrast \(factor)")
                if factor >= 1 {
                    // At or above neutral, white is untouched and the floor is the provider's own.
                    XCTAssertEqual(transfer.scale, max(DimmingComposer.gammaFloor, min(1, dim)))
                }
            }
        }
        // Above the floor, a lowered contrast is applied as asked: white is three quarters of the dim.
        let undimmed = SoftwareImageTransfer(dim: 1, contrast: 0.5)
        XCTAssertEqual(undimmed.scale, 1)
        XCTAssertEqual(undimmed.tables(count: count).red.last ?? 0, 0.75, accuracy: 0.0001)
    }

    func testEveryComposedTableIsMonotonic() {
        for factor: Float in [0.5, 1, 1.5] {
            for boost: Float in [1, 1.8] {
                let tables = SoftwareImageTransfer(dim: 0.4, gains: warm, contrast: factor, boost: boost)
                    .tables(count: count)
                for channel in [tables.red, tables.green, tables.blue] {
                    XCTAssertEqual(channel, channel.sorted(), "contrast \(factor), boost \(boost)")
                }
            }
        }
    }

    // MARK: - Suspension (AM-18)

    func testSuspensionBypassesTemperatureAndContrastButKeepsBrightness() {
        let suspended = SoftwareImageTransfer.composed(dim: 0.6, kelvin: 4000, contrast: 1.3, boost: 1.5,
                                                       suspended: true)
        XCTAssertEqual(suspended, SoftwareImageTransfer(dim: 0.6, boost: 1.5))
        let live = SoftwareImageTransfer.composed(dim: 0.6, kelvin: 4000, contrast: 1.3, boost: 1.5,
                                                  suspended: false)
        XCTAssertEqual(live, SoftwareImageTransfer(dim: 0.6, gains: warm, contrast: 1.3, boost: 1.5))
    }

    func testASuspendedUndimmedDisplayNeedsNoGammaSoTheSlotGoesBackToColorSync() {
        let transfer = SoftwareImageTransfer.composed(dim: 1, kelvin: 3000, contrast: 0.6, boost: 1,
                                                      suspended: true)
        XCTAssertFalse(transfer.needsGamma)
        XCTAssertEqual(GammaSlotPolicy.action(needsGamma: transfer.needsGamma, owned: true, blocked: false), .release)
    }

    func testUnsetValuesComposeToTheUntouchedDisplay() {
        let transfer = SoftwareImageTransfer.composed(dim: 1, kelvin: nil, contrast: nil, boost: 1, suspended: false)
        XCTAssertFalse(transfer.needsGamma)
    }
}
