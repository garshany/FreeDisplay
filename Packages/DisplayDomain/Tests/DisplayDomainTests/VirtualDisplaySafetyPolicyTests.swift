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
