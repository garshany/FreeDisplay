import XCTest
@testable import AutomationSchema

final class BrightnessRoutePolicyTests: XCTestCase {
    func testAppAvailabilityHonorsBuildAndUserRouteOwnership() throws {
        let software = BrightnessRouteAvailability.appRoutes(current: .software, publicAPIOnly: false,
                                                              softwarePreferred: true, ddcRefusal: nil)
        XCTAssertEqual(try BrightnessRoutePolicy.choose(.automatic, availability: software, displayName: "Desk"), .software)
        XCTAssertThrowsError(try BrightnessRoutePolicy.choose(.hardware, availability: software, displayName: "Desk"))
        let publicOnly = BrightnessRouteAvailability.appRoutes(current: .native, publicAPIOnly: true,
                                                               softwarePreferred: false, ddcRefusal: nil)
        XCTAssertNil(publicOnly.current)
        XCTAssertEqual(publicOnly.state(of: .native), .unavailable(.notInThisBuild))
        let ddc = BrightnessRouteAvailability.appRoutes(current: .ddc, publicAPIOnly: false,
                                                        softwarePreferred: false, ddcRefusal: nil)
        XCTAssertEqual(try BrightnessRoutePolicy.choose(.hardware, availability: ddc, displayName: "Desk"), .ddc)
        XCTAssertThrowsError(try BrightnessRoutePolicy.choose(.software, availability: ddc, displayName: "Desk"))
    }

    private func availability(current: BrightnessRoute?, available: [BrightnessRoute],
                              unavailable: [BrightnessRoute: BrightnessRouteUnavailableReason] = [:]) -> BrightnessRouteAvailability {
        var states: [BrightnessRoute: BrightnessRouteAvailability.State] = [:]
        for route in available { states[route] = .available }
        for (route, reason) in unavailable { states[route] = .unavailable(reason) }
        return BrightnessRouteAvailability(current: current, states: states)
    }

    private func choose(_ method: BrightnessMethodRequest, _ availability: BrightnessRouteAvailability) throws -> BrightnessRoute {
        try BrightnessRoutePolicy.choose(method, availability: availability, displayName: "Desk")
    }

    func testMethodSpellings() throws {
        XCTAssertEqual(try BrightnessMethodRequest.parse("auto"), .automatic)
        XCTAssertEqual(try BrightnessMethodRequest.parse("Hardware-Only"), .hardware)
        XCTAssertEqual(try BrightnessMethodRequest.parse("hardware_only"), .hardware)
        XCTAssertEqual(try BrightnessMethodRequest.parse("DDC"), .ddc)
        XCTAssertEqual(try BrightnessMethodRequest.parse("gamma"), .software)
        XCTAssertThrowsError(try BrightnessMethodRequest.parse("magic")) {
            XCTAssertEqual(($0 as? AutomationIssue)?.code, .invalidValue)
        }
    }

    func testAutomaticKeepsTheDisplaysOwnRoute() throws {
        XCTAssertEqual(try choose(.automatic, availability(current: .ddc, available: [.ddc, .software])), .ddc)
        XCTAssertEqual(try choose(.automatic, availability(current: .software, available: [.software])), .software)
        // No current route: native, then DDC, then software.
        XCTAssertEqual(try choose(.automatic, availability(current: nil, available: [.ddc, .software])), .ddc)
        XCTAssertEqual(try choose(.automatic, availability(current: nil, available: [.software, .native])), .native)
    }

    /// TB-36: a hardware-only request never dims pixels in software.
    func testHardwareOnlyRefusesASoftwareOnlyDisplay() {
        let softwareOnly = availability(current: .software, available: [.software],
                                        unavailable: [.native: .notOffered, .ddc: .refused])
        XCTAssertThrowsError(try choose(.hardware, softwareOnly)) { error in
            let issue = error as? AutomationIssue
            XCTAssertEqual(issue?.code, .methodUnavailable)
            XCTAssertEqual(issue?.category, .unsupported)
            XCTAssertTrue(issue?.message.contains("software dimming was not used") ?? false)
            XCTAssertTrue(issue?.message.contains("ddc: withheld for safety") ?? false, issue?.message ?? "")
        }
    }

    func testHardwareOnlyRespectsTheUsersSoftwarePreference() {
        let preferred = availability(current: .software, available: [.software],
                                     unavailable: [.native: .softwarePreferred, .ddc: .softwarePreferred])
        XCTAssertThrowsError(try choose(.hardware, preferred)) { error in
            XCTAssertTrue((error as? AutomationIssue)?.message.contains("set to software dimming") ?? false)
        }
    }

    func testHardwareOnlyPrefersTheCurrentHardwareRouteThenNative() throws {
        XCTAssertEqual(try choose(.hardware, availability(current: .ddc, available: [.native, .ddc])), .ddc)
        XCTAssertEqual(try choose(.hardware, availability(current: .software, available: [.ddc, .software])), .ddc)
        XCTAssertEqual(try choose(.hardware, availability(current: nil, available: [.native, .ddc])), .native)
    }

    func testExplicitRoutesAreHonouredOrRefused() throws {
        let both = availability(current: .native, available: [.native, .software])
        XCTAssertEqual(try choose(.native, both), .native)
        XCTAssertEqual(try choose(.software, both), .software)
        XCTAssertThrowsError(try choose(.ddc, both)) {
            XCTAssertTrue(($0 as? AutomationIssue)?.message.contains("ddc: the display doesn't offer it") ?? false)
        }
        let cli = availability(current: .ddc, available: [.ddc], unavailable: [.software: .notInThisProcess])
        XCTAssertThrowsError(try choose(.software, cli))
    }

    func testNoRouteAtAllIsUnavailable() {
        XCTAssertThrowsError(try choose(.automatic, availability(current: nil, available: []))) {
            XCTAssertEqual(($0 as? AutomationIssue)?.code, .methodUnavailable)
        }
    }

    // MARK: Settlement

    private func settle(_ requested: Double, _ readback: BrightnessReadback, accepted: Bool = true) -> BrightnessSettlement.Verdict {
        BrightnessSettlement.settle(BrightnessWriteReport(requested: AutomationLevel(normalized: requested)!,
                                                          accepted: accepted, readback: readback,
                                                          failure: accepted ? nil : "DDC write failed"))
    }

    func testNativeReadbackMustLandOnTheRequestedWholePercent() {
        XCTAssertEqual(settle(0.4, .level(0.4001)).outcome, .verified)
        XCTAssertTrue(settle(0.4, .level(0.4001)).verifiedByDisplay)
        let off = settle(0.4, .level(0.43))
        XCTAssertEqual(off.outcome, .sent)
        XCTAssertEqual(off.observed?.wholePercent, 43)
        XCTAssertEqual(off.note, "the display reports 43%")
    }

    /// The same one-unit DDC tolerance the app's own write verification uses.
    func testDDCReadbackIsJudgedInMonitorUnitsWithOneUnitTolerance() {
        XCTAssertEqual(settle(0.5, .ddc(current: 35, max: 70)).outcome, .verified)
        XCTAssertEqual(settle(0.5, .ddc(current: 36, max: 70)).outcome, .verified)
        let ignored = settle(0.5, .ddc(current: 18, max: 70))
        XCTAssertEqual(ignored.outcome, .sent)
        XCTAssertEqual(ignored.note, "the panel reports 18/70 instead of 35")
        XCTAssertEqual(settle(0.5, .ddc(current: 5, max: 0)).outcome, .sent)
    }

    func testSoftwareDimmingIsNeverConfirmedByTheDisplay() {
        let verdict = settle(0.05, .applied(0.15))
        XCTAssertEqual(verdict.outcome, .sent)
        XCTAssertFalse(verdict.verifiedByDisplay)
        XCTAssertEqual(verdict.observed?.wholePercent, 15)
        XCTAssertTrue(verdict.note?.contains("applied 15%") ?? false)
    }

    func testNoReadbackIsSentAndARejectedWriteIsFailed() {
        XCTAssertEqual(settle(0.5, .none).outcome, .sent)
        let failed = settle(0.5, .none, accepted: false)
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertEqual(failed.note, "DDC write failed")
    }
}
