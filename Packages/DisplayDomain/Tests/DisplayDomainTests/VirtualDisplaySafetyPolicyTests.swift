import XCTest
@testable import DisplayDomain

final class VirtualDisplaySafetyPolicyTests: XCTestCase {
    func testCreationRefusesHeadlessAndOnlyOwnedVirtualScreens() {
        XCTAssertFalse(VirtualDisplaySafetyPolicy.canCreate(activeSurfaces: []))
        XCTAssertFalse(VirtualDisplaySafetyPolicy.canCreate(activeSurfaces: [
            VirtualDisplaySurface(displayID: 7, vendorID: VirtualDisplaySafetyPolicy.providerVendorID)]))
    }
    func testUnknownVendorIsNotRecoveryEvidence() {
        XCTAssertFalse(VirtualDisplaySafetyPolicy.canCreate(activeSurfaces: [
            VirtualDisplaySurface(displayID: 7, vendorID: 0)]))
    }
    func testCreationAcceptsBuiltinOrIdentifiedExternalSurface() {
        XCTAssertTrue(VirtualDisplaySafetyPolicy.canCreate(activeSurfaces: [
            VirtualDisplaySurface(displayID: 1, vendorID: 0, isBuiltIn: true)]))
        XCTAssertTrue(VirtualDisplaySafetyPolicy.canCreate(activeSurfaces: [
            VirtualDisplaySurface(displayID: 2, vendorID: 123)]))
    }
    func testRemovalRefusesLastScreenAndMirrorSlaves() {
        let source = VirtualDisplaySurface(displayID: 7, vendorID: 0x4f44)
        XCTAssertFalse(VirtualDisplaySafetyPolicy.canRemove(displayID: 7, activeSurfaces: [source]))
        XCTAssertFalse(VirtualDisplaySafetyPolicy.canRemove(displayID: 7, activeSurfaces: [source,
            VirtualDisplaySurface(displayID: 8, vendorID: 123, mirroredSourceID: 7)]))
    }
    func testRemovalRequiresIndependentActiveSurface() {
        XCTAssertTrue(VirtualDisplaySafetyPolicy.canRemove(displayID: 7, activeSurfaces: [
            VirtualDisplaySurface(displayID: 7, vendorID: 0x4f44),
            VirtualDisplaySurface(displayID: 8, vendorID: 123)]))
        XCTAssertFalse(VirtualDisplaySafetyPolicy.canRemove(displayID: 7, activeSurfaces: []))
    }
}

/// AM-02: when the session can classify its surfaces, the same evidence as lifecycle preflight decides.
final class VirtualDisplaySafetyPolicyPresenceTests: XCTestCase {
    func testAnAssessedSurfaceIsJudgedByPresenceNotVendor() {
        // A third-party virtual screen carries a real-looking vendor; the vendor heuristic accepted it.
        XCTAssertFalse(VirtualDisplaySafetyPolicy.canCreate(activeSurfaces: [
            VirtualDisplaySurface(displayID: 2, vendorID: 123, physicalPresence: .unverified)]))
        XCTAssertFalse(VirtualDisplaySafetyPolicy.canCreate(activeSurfaces: [
            VirtualDisplaySurface(displayID: 3, vendorID: 0, isBuiltIn: true, physicalPresence: .virtual)]))
        XCTAssertTrue(VirtualDisplaySafetyPolicy.canCreate(activeSurfaces: [
            VirtualDisplaySurface(displayID: 2, vendorID: 123, physicalPresence: .unverified),
            VirtualDisplaySurface(displayID: 4, vendorID: 0x10AC, physicalPresence: .physical)]))
    }
}
