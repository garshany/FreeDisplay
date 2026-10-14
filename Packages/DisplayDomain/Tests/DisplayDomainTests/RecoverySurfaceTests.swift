import XCTest
@testable import DisplayDomain

/// AM-02 / SD-07: which displays a safeguard may count as "a screen the user still has".
final class PhysicalPresenceClassifierTests: XCTestCase {
    private typealias Display = PhysicalPresenceClassifier.Display
    private typealias Node = PhysicalPresenceClassifier.HardwareNode

    private let builtIn = Display(id: 1, isBuiltIn: true, vendorNumber: 0x0610, modelNumber: 0xA050)
    private func external(_ id: UInt32, vendor: UInt32 = 0x10AC, model: UInt32 = 0x4242,
                          serial: UInt32 = 0) -> Display {
        Display(id: id, vendorNumber: vendor, modelNumber: model, serialNumber: serial)
    }
    private func node(vendor: Int? = 0x10AC, model: Int? = 0x4242, serial: Int? = nil) -> Node {
        Node(legacyManufacturerID: vendor, productID: model, serialNumber: serial)
    }

    func testTheBuiltInPanelIsPhysicalWithoutAnyNode() {
        XCTAssertEqual(PhysicalPresenceClassifier.classify([builtIn], hardware: []), [1: .physical])
    }

    func testAnExternalTheHardwareDrivesIsPhysical() {
        let presence = PhysicalPresenceClassifier.classify(
            [builtIn, external(2)], hardware: [node(vendor: 0x0610, model: 0xA050), node()])
        XCTAssertEqual(presence[2], .physical)
    }

    /// BetterDisplay, DisplayLink, Sidecar: online, active, a vendor and modes — and no hardware.
    func testAnExternalWithNoHardwareBehindItIsUnverified() {
        let presence = PhysicalPresenceClassifier.classify([builtIn, external(9, vendor: 0x1234, model: 7)],
                                                           hardware: [node(vendor: 0x0610, model: 0xA050)])
        XCTAssertEqual(presence[9], .unverified)
    }

    func testOurOwnEndpointsAndTheSystemPlaceholderAreVirtual() {
        let ours = external(5, vendor: VirtualDisplaySafetyPolicy.providerVendorID, model: 1)
        let placeholder = Display(id: 6, isSystemPlaceholder: true,
                                  vendorNumber: DisplayActivity.placeholderVendor,
                                  modelNumber: DisplayActivity.placeholderModel)
        // Even a node that happens to match must not turn our own endpoint into a monitor.
        let presence = PhysicalPresenceClassifier.classify(
            [ours, placeholder], hardware: [node(vendor: Int(VirtualDisplaySafetyPolicy.providerVendorID), model: 1)])
        XCTAssertEqual(presence, [5: .virtual, 6: .virtual])
    }

    func testTwoIdenticalMonitorsWithTwoNodesAreBothPhysical() {
        let presence = PhysicalPresenceClassifier.classify([external(2), external(3)],
                                                           hardware: [node(), node()])
        XCTAssertEqual(presence, [2: .physical, 3: .physical])
    }

    /// More claimants than hardware: nothing says which one is the impostor, so neither counts.
    func testAVirtualScreenCopyingAMonitorsIdentityMakesBothUnverified() {
        let presence = PhysicalPresenceClassifier.classify([external(2), external(3)], hardware: [node()])
        XCTAssertEqual(presence, [2: .unverified, 3: .unverified])
    }

    func testTheBuiltInsNodeCannotVouchForAnExternalCopyingIt() {
        let copycat = external(4, vendor: 0x0610, model: 0xA050)
        let presence = PhysicalPresenceClassifier.classify([builtIn, copycat],
                                                           hardware: [node(vendor: 0x0610, model: 0xA050)])
        XCTAssertEqual(presence[4], .unverified)
    }

    func testSerialsPickTheirOwnNodeAndContradictionsDontMatch() {
        XCTAssertEqual(PhysicalPresenceClassifier.classify(
            [external(2, serial: 5)], hardware: [node(serial: 6)])[2], .unverified)
        // The serial-less unit must not take the node the serialled unit needs.
        let presence = PhysicalPresenceClassifier.classify(
            [external(2, serial: 0), external(3, serial: 6)], hardware: [node(serial: 6), node(serial: nil)])
        XCTAssertEqual(presence, [2: .physical, 3: .physical])
    }

    func testAnEDIDlessDisplayIsVouchedForOnlyByAnAnonymousNode() {
        let blank = external(2, vendor: 0, model: 0)
        XCTAssertEqual(PhysicalPresenceClassifier.classify([blank], hardware: [node(vendor: nil, model: nil)])[2],
                       .physical)
        XCTAssertEqual(PhysicalPresenceClassifier.classify([blank], hardware: [node()])[2], .unverified)
        XCTAssertEqual(PhysicalPresenceClassifier.classify([external(3)], hardware: [node(vendor: nil, model: nil)])[3],
                       .unverified)
    }

    func testAPNPManufacturerIDIsReadWhenTheNumericOneIsMissing() {
        let named = Node(manufacturerID: "DEL", productID: 0x4242)
        XCTAssertEqual(PhysicalPresenceClassifier.classify([external(2)], hardware: [named])[2], .physical)
        let zeroed = Node(legacyManufacturerID: 0, manufacturerID: "DEL", productID: 0x4242)
        XCTAssertEqual(PhysicalPresenceClassifier.classify([external(2)], hardware: [zeroed])[2], .physical)
    }

    /// A serial the hardware also reports proves that display, even beside a same-model screen
    /// (e.g. a DisplayLink twin) that has no hardware of its own.
    func testASerialMatchSettlesItsDisplayBesideAnImpostor() {
        let presence = PhysicalPresenceClassifier.classify(
            [external(2, serial: 11), external(3, serial: 22)], hardware: [node(serial: 11)])
        XCTAssertEqual(presence, [2: .physical, 3: .unverified])
    }

    func testAnImpostorCopyingTheSerialTooLeavesBothUnverified() {
        let presence = PhysicalPresenceClassifier.classify(
            [external(2, serial: 11), external(3, serial: 11)], hardware: [node(serial: 11)])
        XCTAssertEqual(presence, [2: .unverified, 3: .unverified])
    }
}

final class RecoverySurfacePolicyTests: XCTestCase {
    private func obs(_ id: String, active: Bool = true, klass: DisplayClass = .external,
                     presence: PhysicalPresence? = nil, mirrorOf: String? = nil,
                     overlay: PresentationOverlay = .visible) -> DisplayObservation {
        DisplayObservation(recordID: DisplayRecordID(rawValue: id), isActive: active, overlay: overlay,
                           mirrorSourceID: mirrorOf.map(DisplayRecordID.init(rawValue:)),
                           displayClass: klass, physicalPresence: presence, generation: .initial)
    }

    func testAnAssessedPresenceDecides() {
        XCTAssertTrue(RecoverySurfacePolicy.isPhysical(obs("a", presence: .physical)))
        XCTAssertFalse(RecoverySurfacePolicy.isPhysical(obs("b", presence: .unverified)))
        XCTAssertFalse(RecoverySurfacePolicy.isPhysical(obs("c", presence: .virtual)))
    }

    func testUnassessedObservationsFallBackToTheirClass() {
        XCTAssertTrue(RecoverySurfacePolicy.isPhysical(obs("a", klass: .builtIn)))
        XCTAssertTrue(RecoverySurfacePolicy.isPhysical(obs("b", klass: .external)))
        for klass in [DisplayClass.virtual, .sidecar, .airplay, .headlessAdapter] {
            XCTAssertFalse(RecoverySurfacePolicy.isPhysical(obs("x", klass: klass)), "\(klass)")
        }
    }

    func testOnlyLitPhysicalUnmirroredVisibleScreensAreSafeSurfaces() {
        let world = [
            obs("builtin", klass: .builtIn, presence: .physical),
            obs("ours", klass: .virtual, presence: .virtual),
            obs("displaylink", presence: .unverified),
            obs("asleep-off", active: false, presence: .physical),
            obs("mirror", presence: .physical, mirrorOf: "builtin"),
            obs("blacked", presence: .physical, overlay: .blackedOut)
        ]
        XCTAssertEqual(RecoverySurfacePolicy.liveSurfaces(in: world).map(\.recordID.rawValue),
                       ["builtin", "mirror", "blacked"])
        XCTAssertEqual(RecoverySurfacePolicy.safeSurfaceCandidates(in: world, excluding: []).map(\.recordID.rawValue),
                       ["builtin"])
        XCTAssertTrue(RecoverySurfacePolicy.safeSurfaceCandidates(
            in: world, excluding: [DisplayRecordID(rawValue: "builtin")]).isEmpty,
            "a virtual or unverified screen is never the one left on")
    }

    func testAnOldSnapshotWithoutPresenceStillDecodes() throws {
        let encoded = try JSONEncoder().encode(obs("a", klass: .builtIn))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "physicalPresence")
        let decoded = try JSONDecoder().decode(DisplayObservation.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.physicalPresence)
        XCTAssertTrue(RecoverySurfacePolicy.isPhysical(decoded))
    }
}
