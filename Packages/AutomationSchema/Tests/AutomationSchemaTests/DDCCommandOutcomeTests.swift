import XCTest
@testable import AutomationSchema

final class DDCCommandOutcomeTests: XCTestCase {
    func testTransportResultMapsToSentOrFailed() {
        XCTAssertEqual(DDCCommandOutcome(transportAccepted: true), .sent)
        XCTAssertEqual(DDCCommandOutcome(transportAccepted: false), .failed)
        XCTAssertEqual(DDCCommandOutcome.notSent.auditStatus, "notSent")
    }

    // MARK: - Power risk (AM-04 / SD-03)

    func testOnlyScreenOutranksMainDisplay() {
        // The last visible screen is the strongest warning whether or not it is main.
        XCTAssertEqual(DDCPowerRisk.assess(isMain: true, otherVisibleScreens: 0), .onlyScreen)
        XCTAssertEqual(DDCPowerRisk.assess(isMain: false, otherVisibleScreens: 0), .onlyScreen)
    }

    func testMainDisplayWithOtherScreens() {
        XCTAssertEqual(DDCPowerRisk.assess(isMain: true, otherVisibleScreens: 1), .mainDisplay)
    }

    func testSecondaryDisplayWithOtherScreens() {
        XCTAssertEqual(DDCPowerRisk.assess(isMain: false, otherVisibleScreens: 2), .otherScreensRemain)
    }

    func testOnlyDisruptiveModesNeedConfirmation() {
        XCTAssertFalse(DDCPowerMode.on.needsConfirmation)
        XCTAssertTrue(DDCPowerMode.standby.needsConfirmation)
        XCTAssertTrue(DDCPowerMode.off.needsConfirmation)
    }

    // MARK: - Input switch (AM-05)

    func testFailedOrUnsentSwitchKeepsTheReportedInput() {
        XCTAssertEqual(DDCInputSwitch.reportedInput(after: .failed, requested: 0x11, previouslyReported: 0x0F), 0x0F)
        XCTAssertEqual(DDCInputSwitch.reportedInput(after: .notSent, requested: 0x11, previouslyReported: 0x0F), 0x0F)
        XCTAssertNil(DDCInputSwitch.reportedInput(after: .failed, requested: 0x11, previouslyReported: nil))
    }

    func testSentSwitchMakesTheOldReportUnknownWithoutClaimingTheRequest() {
        // The regression: a sent request used to become the checkmark before anything confirmed it.
        XCTAssertNil(DDCInputSwitch.reportedInput(after: .sent, requested: 0x11, previouslyReported: 0x0F))
        XCTAssertNil(DDCInputSwitch.reportedInput(after: .sent, requested: 0x11, previouslyReported: nil))
    }

    func testSentSwitchToTheAlreadyReportedInputKeepsIt() {
        XCTAssertEqual(DDCInputSwitch.reportedInput(after: .sent, requested: 0x11, previouslyReported: 0x11), 0x11)
    }

    func testStatusFollowsTheOutcome() {
        XCTAssertEqual(DDCInputSwitch(requested: 0x11, outcome: .sent).status, .sent)
        XCTAssertEqual(DDCInputSwitch(requested: 0x11, outcome: .failed).status, .failed)
        XCTAssertEqual(DDCInputSwitch(requested: 0x11, outcome: .notSent).status, .notSent)
    }
}
