import XCTest
@testable import DisplayDomain

final class DDCServiceMatcherTests: XCTestCase {
    private typealias Matcher = DDCServiceMatcher

    // MARK: - PnP vendor decode

    func testVendorNumberFromPNPKnownVendors() {
        // Reference values from the UEFI PnP registry: these are the wire values EDID carries.
        XCTAssertEqual(Matcher.vendorNumber(fromPNP: "SAM"), 0x4C2D)  // Samsung
        XCTAssertEqual(Matcher.vendorNumber(fromPNP: "GSM"), 0x1E6D)  // LG
        XCTAssertEqual(Matcher.vendorNumber(fromPNP: "DEL"), 0x10AC)  // Dell
        XCTAssertEqual(Matcher.vendorNumber(fromPNP: "gsm"), 0x1E6D)  // case-insensitive
    }

    func testVendorNumberFromPNPRejectsMalformed() {
        XCTAssertNil(Matcher.vendorNumber(fromPNP: ""))
        XCTAssertNil(Matcher.vendorNumber(fromPNP: "SA"))
        XCTAssertNil(Matcher.vendorNumber(fromPNP: "SAMS"))
        XCTAssertNil(Matcher.vendorNumber(fromPNP: "S4M"))
    }

    // MARK: - Scoring

    func testScoreWeightsSerialOverProductOverVendor() {
        let target = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 777)
        let vendorOnly = Matcher.Candidate(legacyManufacturerID: 0x4C2D)
        let productOnly = Matcher.Candidate(productID: 0x1001)
        let serialOnly = Matcher.Candidate(serialNumber: 777)
        // serial (4) > product (2) > vendor (1); product+vendor (3) still loses to serial.
        XCTAssertEqual(Matcher.score(vendorOnly, against: target), 1)
        XCTAssertEqual(Matcher.score(productOnly, against: target), 2)
        XCTAssertEqual(Matcher.score(serialOnly, against: target), 4)
        let vendorAndProduct = Matcher.Candidate(legacyManufacturerID: 0x4C2D, productID: 0x1001)
        XCTAssertLessThan(Matcher.score(vendorAndProduct, against: target),
                          Matcher.score(serialOnly, against: target))
    }

    func testScoreFallsBackToPNPStringWhenLegacyIDMissing() {
        let target = Matcher.Target(vendorNumber: 0x1E6D, productNumber: 0, serialNumber: 0)
        XCTAssertEqual(Matcher.score(.init(manufacturerID: "GSM"), against: target), 1)
    }

    func testScoreIgnoresZeroFields() {
        // Serial 0 = "not programmed" on both sides; matching 0 == 0 would pair any two such panels.
        let target = Matcher.Target(vendorNumber: 0, productNumber: 0, serialNumber: 0)
        let zeros = Matcher.Candidate(legacyManufacturerID: 0, productID: 0, serialNumber: 0)
        XCTAssertEqual(Matcher.score(zeros, against: target), 0)
    }

    // MARK: - Resolution (TR-06: refuse instead of guessing by order)

    func testResolvePicksIdentityMatchOverOrder() {
        // The regression the matcher exists for: CG order says index 0, identity says index 1.
        let target = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 777)
        let dell = Matcher.Target(vendorNumber: 0x10AC, productNumber: 0x2002, serialNumber: 111)
        let candidates: [Matcher.Candidate?] = [
            .init(legacyManufacturerID: 0x10AC, productID: 0x2002, serialNumber: 111),  // the Dell
            .init(legacyManufacturerID: 0x4C2D, productID: 0x1001, serialNumber: 777),  // the Samsung
        ]
        XCTAssertEqual(Matcher.resolve(candidates, against: target, among: [dell, target]), .matched(index: 1))
    }

    func testResolveUniqueWinnerBeatsWeakerMatch() {
        // A strictly better identity match wins even though another service shares the model.
        let target = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 777)
        let sibling = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 888)
        let candidates: [Matcher.Candidate?] = [
            .init(legacyManufacturerID: 0x4C2D, productID: 0x1001, serialNumber: 888),  // the sibling
            .init(legacyManufacturerID: 0x4C2D, productID: 0x1001, serialNumber: 777),  // exact unit
        ]
        XCTAssertEqual(Matcher.resolve(candidates, against: target, among: [sibling, target]), .matched(index: 1))
    }

    func testResolveRefusesTiedIdenticalMonitors() {
        // Two identical panels with unprogrammed serials tie on vendor+product. The old matcher picked
        // by enumeration order, which can swap after a dock replug — now nothing is bound.
        let target = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 0)
        let twin = Matcher.Candidate(legacyManufacturerID: 0x4C2D, productID: 0x1001, serialNumber: 0)
        XCTAssertEqual(Matcher.resolve([twin, twin], against: target, among: [target, target]),
                       .refused(.ambiguousIdentity))
    }

    func testResolveRefusesWhenAnotherDisplayHasTheSameIdentity() {
        // Identical twins where IOKit labels only one service: the labelled service matches BOTH
        // displays, so binding it would let the second twin's commands reach the first.
        let twin = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 0)
        let candidates: [Matcher.Candidate?] = [
            .init(legacyManufacturerID: 0x4C2D, productID: 0x1001, serialNumber: 0), nil,
        ]
        XCTAssertEqual(Matcher.resolve(candidates, against: twin, among: [twin, twin]),
                       .refused(.ambiguousIdentity))
    }

    func testResolveRefusesUnidentifiedServicesWithSeveralDisplays() {
        // No attributes anywhere and two monitors: the old order fallback is exactly the guess removed.
        let target = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 777)
        let other = Matcher.Target(vendorNumber: 0x10AC, productNumber: 0x2002, serialNumber: 111)
        XCTAssertEqual(Matcher.resolve([nil, nil], against: target, among: [target, other]),
                       .refused(.unidentified))
        // One service but two displays (e.g. a DisplayLink panel next to a TV that strips its
        // attributes): the service may belong to the other display.
        XCTAssertEqual(Matcher.resolve([nil], against: target, among: [target, other]),
                       .refused(.unidentified))
    }

    func testResolveNeverLendsAnotherMonitorsServiceToADisplayWithoutOne() {
        // A display without its own AV service (DisplayLink, Sidecar, another app's virtual screen)
        // next to a labelled monitor: the monitor's service scores zero for it and must not be borrowed.
        let serviceless = Matcher.Target(vendorNumber: 0x05E3, productNumber: 0x0001, serialNumber: 5)
        let monitor = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 777)
        let candidates: [Matcher.Candidate?] = [
            .init(legacyManufacturerID: 0x4C2D, productID: 0x1001, serialNumber: 777),
        ]
        XCTAssertEqual(Matcher.resolve(candidates, against: serviceless, among: [monitor, serviceless]),
                       .refused(.unidentified))
        // …while the monitor itself still binds.
        XCTAssertEqual(Matcher.resolve(candidates, against: monitor, among: [monitor, serviceless]),
                       .matched(index: 0))
    }

    func testResolveSingleMonitorWithoutAttributesStillBinds() {
        // The common single-TV setup keeps working: one service, one external — nothing else to reach.
        let target = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 0)
        XCTAssertEqual(Matcher.resolve([nil], against: target, among: [target]), .sole(index: 0))
        // Same when the only service's attributes don't line up with CG's (e.g. an EDID override):
        // still the only monitor, so still bound as before.
        let mismatched: [Matcher.Candidate?] = [.init(legacyManufacturerID: 0x10AC, productID: 0x2002)]
        XCTAssertEqual(Matcher.resolve(mismatched, against: target, among: [target]), .sole(index: 0))
    }

    func testResolveWithNoServices() {
        let target = Matcher.Target(vendorNumber: 0x4C2D, productNumber: 0x1001, serialNumber: 777)
        XCTAssertEqual(Matcher.resolve([], against: target, among: [target]), .none)
    }

    // MARK: - Apple display eligibility (FB-08)

    func testAppleDisplaysNeedTheExplicitOverride() {
        XCTAssertFalse(DDCEligibility.allowsGenericDDC(vendorNumber: 0x0610, appleOverride: false))
        XCTAssertTrue(DDCEligibility.allowsGenericDDC(vendorNumber: 0x0610, appleOverride: true))
        XCTAssertTrue(DDCEligibility.isAppleDisplay(vendorNumber: 0x0610))
        // "APP" decodes to Apple's EDID vendor number — the same constant the gate uses.
        XCTAssertEqual(Matcher.vendorNumber(fromPNP: "APP"), DDCEligibility.appleVendorNumber)
    }

    func testNonAppleDisplaysAreUnaffected() {
        XCTAssertTrue(DDCEligibility.allowsGenericDDC(vendorNumber: 0x4C2D, appleOverride: false))
        XCTAssertTrue(DDCEligibility.allowsGenericDDC(vendorNumber: 0, appleOverride: false))
        XCTAssertFalse(DDCEligibility.isAppleDisplay(vendorNumber: 0x1E6D))
    }
}
