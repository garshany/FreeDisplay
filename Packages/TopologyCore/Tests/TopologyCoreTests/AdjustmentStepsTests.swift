import XCTest
@testable import TopologyCore

final class AdjustmentStepsTests: XCTestCase {
    func testDefaultsAreMacOSSixteenthAndSixtyFourthSteps() {
        let steps = AdjustmentSteps.default
        XCTAssertEqual(steps.effectiveRange, 64)
        XCTAssertEqual(steps.effectiveStandard, 4)
        XCTAssertEqual(steps.effectiveFine, 1)
        XCTAssertEqual(steps.fraction(fine: false), 1.0 / 16.0)
        XCTAssertEqual(steps.fraction(fine: true), 1.0 / 64.0)
    }

    func testDefaultStepsMatchTheFixedMediaKeySteps() {
        // The native keys moved to the shared policy; with nothing configured they must not change.
        for action in MediaKeyAction.allCases {
            for fine in [false, true] {
                XCTAssertEqual(action.signedDelta(fineStep: fine, steps: .default), action.signedDelta(fineStep: fine))
            }
        }
    }

    func testEachBlankFieldFallsBackToItsOwnDefault() {
        let steps = AdjustmentSteps(range: 100, standard: nil, fine: 2)
        XCTAssertEqual(steps.effectiveRange, 100)
        XCTAssertEqual(steps.effectiveStandard, 4)  // blank → its default, independent of the others
        XCTAssertEqual(steps.effectiveFine, 2)
        XCTAssertEqual(steps.fraction(fine: false), 0.04, accuracy: 1e-6)
        XCTAssertEqual(steps.fraction(fine: true), 0.02, accuracy: 1e-6)
    }

    func testAValueThatCantDescribeAStepIsKeptButNotUsed() {
        let steps = AdjustmentSteps(range: 0, standard: -3, fine: 0)
        XCTAssertEqual(steps.range, 0)  // stored as typed, so the editor shows it
        XCTAssertEqual(steps.effectiveRange, 64)
        XCTAssertEqual(steps.effectiveStandard, 4)
        XCTAssertEqual(steps.effectiveFine, 1)
    }

    func testAStepWiderThanTheSpanMovesTheWholeSpan() {
        XCTAssertEqual(AdjustmentSteps(range: 8, standard: 20).fraction(fine: false), 1)
    }

    func testFineByDefaultInvertsOnlyTheNativeKeyModifier() {
        let steps = AdjustmentSteps(fineByDefault: true)
        XCTAssertEqual(steps.nativeKeyFraction(modifierRequestsFine: false), 1.0 / 64.0)
        XCTAssertEqual(steps.nativeKeyFraction(modifierRequestsFine: true), 1.0 / 16.0)
        // Explicit standard/fine requests (the shortcut actions) are unaffected.
        XCTAssertEqual(steps.fraction(fine: false), 1.0 / 16.0)
        XCTAssertEqual(steps.fraction(fine: true), 1.0 / 64.0)
        XCTAssertEqual(MediaKeyAction.brightnessDown.signedDelta(fineStep: false, steps: steps), -1.0 / 64.0)
    }

    func testNativeKeysAndShortcutActionsRequestTheSameFractions() {
        let steps = AdjustmentSteps(range: 32, standard: 3, fine: 1)
        XCTAssertEqual(MediaKeyAction.brightnessUp.signedDelta(fineStep: false, steps: steps), steps.fraction(fine: false))
        XCTAssertEqual(MediaKeyAction.brightnessUp.signedDelta(fineStep: true, steps: steps), steps.fraction(fine: true))
    }

    func testParsingTreatsBlankAndTextAsNoOverride() {
        XCTAssertNil(AdjustmentSteps.parse(""))
        XCTAssertNil(AdjustmentSteps.parse("   "))
        XCTAssertNil(AdjustmentSteps.parse("abc"))
        XCTAssertEqual(AdjustmentSteps.parse(" 12 "), 12)
        XCTAssertEqual(AdjustmentSteps.parse("0"), 0)
    }

    func testRoundTripsThroughTheSettingsFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("od-steps-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        XCTAssertEqual(store.load().adjustmentSteps, .default)
        let steps = AdjustmentSteps(range: 100, standard: nil, fine: 3, fineByDefault: true)
        try store.save(OpenDisplaySettings(adjustmentSteps: steps))
        XCTAssertEqual(store.load().adjustmentSteps, steps)
    }

    func testAnUnreadableFieldLosesOnlyItself() throws {
        let json = #"{"range": "many", "standard": 8, "fineByDefault": true}"#
        let steps = try JSONDecoder().decode(AdjustmentSteps.self, from: Data(json.utf8))
        XCTAssertNil(steps.range)
        XCTAssertEqual(steps.standard, 8)
        XCTAssertNil(steps.fine)
        XCTAssertTrue(steps.fineByDefault)
    }
}
