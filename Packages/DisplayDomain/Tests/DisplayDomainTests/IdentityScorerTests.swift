import XCTest
@testable import DisplayDomain

final class IdentityScorerTests: XCTestCase {
    private func record(serial: String?, vendor: Int? = 610, product: Int? = 123, paired: Bool = false) -> DisplayRecord {
        DisplayRecord(
            id: .generate(),
            fingerprint: DisplayFingerprint(vendorID: vendor, productID: product, serialNumber: serial, modelName: "Test 4K"),
            pairingConfirmed: paired
        )
    }

    func testMatchingSerialClearsDestructiveThreshold() {
        let candidate = record(serial: "ABC123")
        let observed = DisplayFingerprint(vendorID: 610, productID: 123, serialNumber: "ABC123")
        let confidence = IdentityScorer.score(observed: observed, candidate: candidate)
        XCTAssertGreaterThanOrEqual(confidence.score, IdentityConfidence.destructiveThreshold,
                                    "A matching EDID serial must be enough to act destructively.")
    }

    func testIdenticalModelWithoutSerialStaysBelowThreshold() {
        // Two identical monitors: same vendor/product, no serial, only topology evidence. This must
        // NOT clear the destructive threshold without explicit pairing (REG-004, §9.2 invariant 4).
        let candidate = record(serial: nil)
        let observed = DisplayFingerprint(vendorID: 610, productID: 123, serialNumber: nil)
        let confidence = IdentityScorer.score(observed: observed, candidate: candidate, topologyMatches: true)
        XCTAssertLessThan(confidence.score, IdentityConfidence.destructiveThreshold)
    }

    func testExplicitPairingClearsThreshold() {
        let candidate = record(serial: nil, paired: true)
        let observed = DisplayFingerprint(vendorID: 610, productID: 123, serialNumber: nil)
        let confidence = IdentityScorer.score(observed: observed, candidate: candidate, explicitPairing: true)
        XCTAssertGreaterThanOrEqual(confidence.score, IdentityConfidence.destructiveThreshold)
    }

    func testScoreIsClampedToUnitInterval() {
        let candidate = record(serial: "ABC123", paired: true)
        let observed = DisplayFingerprint(vendorID: 610, productID: 123, serialNumber: "ABC123")
        let confidence = IdentityScorer.score(observed: observed, candidate: candidate,
                                              explicitPairing: true, aliasMatches: true,
                                              ioPathMatches: true, topologyMatches: true, cgUUIDMatches: true)
        XCTAssertLessThanOrEqual(confidence.score, 1.0)
        XCTAssertGreaterThanOrEqual(confidence.score, 0.0)
    }

    /// TR-09: a serial is only an identity inside one vendor's product line. Two vendors' displays
    /// (or two models) that share a small or placeholder serial must not clear any threshold on it.
    func testTheSameSerialFromAnotherVendorOrModelIsNotASerialMatch() {
        let candidate = record(serial: "16843009", vendor: 610, product: 123)
        let otherVendor = DisplayFingerprint(vendorID: 1234, productID: 123, serialNumber: "16843009")
        let otherModel = DisplayFingerprint(vendorID: 610, productID: 999, serialNumber: "16843009")
        for observed in [otherVendor, otherModel] {
            let confidence = IdentityScorer.score(observed: observed, candidate: candidate)
            XCTAssertLessThan(confidence.score, 0.5, "\(observed)")
            XCTAssertFalse(confidence.evidence.contains { $0.signal == .edidSerial && $0.matched })
        }
    }

    func testASerialWithoutVendorOrModelCannotBeQualified() {
        let a = DisplayFingerprint(vendorID: nil, productID: 123, serialNumber: "S1")
        let b = DisplayFingerprint(vendorID: nil, productID: 123, serialNumber: "S1")
        XCTAssertFalse(IdentityScorer.serialsMatch(a, b))
        XCTAssertTrue(IdentityScorer.serialsMatch(
            DisplayFingerprint(vendorID: 1, productID: 2, serialNumber: "S1"),
            DisplayFingerprint(vendorID: 1, productID: 2, serialNumber: "S1")))
    }

    func testIdentitiesConflictOnlyOnPositiveDifferences() {
        let base = DisplayFingerprint(vendorID: 1, productID: 2, serialNumber: "S1")
        XCTAssertTrue(IdentityScorer.identitiesConflict(base, DisplayFingerprint(vendorID: 9, productID: 2, serialNumber: "S1")))
        XCTAssertTrue(IdentityScorer.identitiesConflict(base, DisplayFingerprint(vendorID: 1, productID: 2, serialNumber: "S2")))
        XCTAssertFalse(IdentityScorer.identitiesConflict(base, DisplayFingerprint(vendorID: 1, productID: 2)))
        XCTAssertFalse(IdentityScorer.identitiesConflict(base, DisplayFingerprint(vendorID: nil, productID: 2, serialNumber: "S9")))
        XCTAssertFalse(IdentityScorer.identitiesConflict(base, base))
    }
}
