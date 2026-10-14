import XCTest
@testable import TopologyCore

final class ICCProfileCatalogTests: XCTestCase {
    private let user = "/Users/pat/Library/ColorSync/Profiles"
    private let factory = "/Library/ColorSync/Profiles/Displays/Studio Display-ABCD.icc"

    private func provenance(_ path: String, factories: [String] = []) -> ICCProfileProvenance {
        ICCProfileCatalog.provenance(of: path, factoryPaths: factories, userFolder: user)
    }

    func testProvenanceFollowsTheFolderAndTheDisplaysOwnFactoryFiles() {
        XCTAssertEqual(provenance("/System/Library/ColorSync/Profiles/sRGB Profile.icc"), .system)
        XCTAssertEqual(provenance(factory), .factory)
        XCTAssertEqual(provenance("/Library/ColorSync/Profiles/Displays/Other-1234.icc"), .factory)
        XCTAssertEqual(provenance("\(user)/Calibrated.icc"), .user)
        XCTAssertEqual(provenance("\(user)/Displays/Mine.icc"), .user, "the user's own Displays folder is not the shared one")
        XCTAssertEqual(provenance("/Library/ColorSync/Profiles/Vendor.icc"), .shared)
        XCTAssertEqual(provenance("/Applications/Tool.app/Contents/Resources/Proof.icc"), .other)
        // A display's factory file is factory wherever ColorSync keeps it.
        XCTAssertEqual(provenance("\(user)/Factory Copy.icc", factories: ["\(user)/Factory Copy.icc"]), .factory)
        // Paths are compared standardized; a sibling folder sharing the prefix is not inside.
        XCTAssertEqual(provenance("\(user)/../Profiles/Calibrated.icc"), .user)
        XCTAssertEqual(provenance("/Users/pat/Library/ColorSync/Profiles Old/X.icc"), .other)
    }

    /// The gamma safeguard and the profile card must agree on what a custom profile is.
    func testProvenanceAgreesWithTheGammaSafeguard() {
        let paths = ["/System/Library/ColorSync/Profiles/Display P3.icc", factory,
                     "/Library/ColorSync/Profiles/Displays/Other-1234.icc", "\(user)/Calibrated.icc",
                     "\(user)/Displays/Mine.icc", "/Library/ColorSync/Profiles/Vendor.icc",
                     "/Applications/Tool.app/Contents/Resources/Proof.icc"]
        for path in paths {
            XCTAssertEqual(ICCProfileCatalog.guardAssignment(for: provenance(path, factories: [factory])),
                           ColorProfileGuard.classify(assignedPath: path, factoryPaths: [factory]), path)
        }
    }

    func testOnlyTheUsersOwnCopiesAreRemovable() {
        XCTAssertEqual(ICCProfileProvenance.allCases.filter(ICCProfileCatalog.isRemovable), [.user])
    }

    func testProfileFileNames() {
        XCTAssertTrue(ICCProfileCatalog.isProfileFileName("Monitor.icc"))
        XCTAssertTrue(ICCProfileCatalog.isProfileFileName("Monitor.ICM"))
        XCTAssertFalse(ICCProfileCatalog.isProfileFileName("Monitor.txt"))
        XCTAssertFalse(ICCProfileCatalog.isProfileFileName("icc"))
    }

    func testAnImportNeverTakesAnExistingName() {
        XCTAssertEqual(ICCProfileCatalog.importFileName(for: "Panel.icc", existing: ["Other.icc"]), "Panel.icc")
        XCTAssertEqual(ICCProfileCatalog.importFileName(for: "Panel.icc", existing: ["panel.ICC"]), "Panel 2.icc")
        XCTAssertEqual(ICCProfileCatalog.importFileName(for: "Panel.icc", existing: ["Panel.icc", "Panel 2.icc"]),
                       "Panel 3.icc")
        XCTAssertEqual(ICCProfileCatalog.importFileName(for: "Panel", existing: ["Panel"]), "Panel 2")
    }

    // MARK: - Header

    private func header(class deviceClass: String = "mntr", space: String = "RGB ", pcs: String = "XYZ ",
                        version: (UInt8, UInt8) = (4, 0x30), date: [UInt16] = [2024, 3, 9, 12, 30, 5],
                        signature: String = "acsp", creator: String = "appl") -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128)
        func put(_ text: String, _ offset: Int) {
            for (index, byte) in text.utf8.prefix(4).enumerated() { bytes[offset + index] = byte }
        }
        bytes[8] = version.0
        bytes[9] = version.1
        put(deviceClass, 12)
        put(space, 16)
        put(pcs, 20)
        for (index, value) in date.enumerated() {
            bytes[24 + 2 * index] = UInt8(value >> 8)
            bytes[25 + 2 * index] = UInt8(value & 0xFF)
        }
        put(signature, 36)
        put(creator, 80)
        return bytes
    }

    func testTheHeaderNamesClassSpaceVersionAndDate() throws {
        let parsed = try XCTUnwrap(ICCProfileHeader(bytes: header()))
        XCTAssertEqual(parsed.deviceClass, "mntr")
        XCTAssertEqual(parsed.colorSpace, "RGB")
        XCTAssertEqual(parsed.connectionSpace, "XYZ")
        XCTAssertEqual(parsed.version, "4.3")
        XCTAssertEqual(parsed.creator, "appl")
        XCTAssertTrue(parsed.isDisplayClass)
        XCTAssertTrue(parsed.isRGB)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(parsed.created, calendar.date(from: DateComponents(year: 2024, month: 3, day: 9,
                                                                         hour: 12, minute: 30, second: 5)))

        let v2 = try XCTUnwrap(ICCProfileHeader(bytes: header(class: "spac", space: "GRAY", version: (2, 0x11),
                                                             date: [0, 0, 0, 0, 0, 0], creator: "")))
        XCTAssertEqual(v2.version, "2.1.1")
        XCTAssertFalse(v2.isDisplayClass)
        XCTAssertFalse(v2.isRGB)
        XCTAssertNil(v2.created, "an all-zero date is no date")
        XCTAssertNil(v2.creator)
    }

    func testANonProfileHasNoHeader() {
        XCTAssertNil(ICCProfileHeader(bytes: header(signature: "nope")))
        XCTAssertNil(ICCProfileHeader(bytes: Array(header().prefix(127))))
    }
}
