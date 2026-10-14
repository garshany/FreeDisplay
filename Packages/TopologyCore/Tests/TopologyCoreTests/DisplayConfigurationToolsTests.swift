// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TopologyCore

final class DisplayConfigurationToolsTests: XCTestCase {
    private func fixture(extensions: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128 * (extensions + 1))
        bytes.replaceSubrange(0..<8, with: [0,255,255,255,255,255,255,0])
        bytes[8] = 4; bytes[9] = 67 // ABC
        bytes[10] = 0x34; bytes[11] = 0x12
        bytes[12] = 0x78; bytes[13] = 0x56
        bytes[57] = 0xfc
        bytes.replaceSubrange(59..<72, with: Array("Test Monitor\n".utf8))
        bytes[126] = UInt8(extensions)
        for block in 0...extensions {
            let start = block * 128
            bytes[start + 127] = UInt8((256 - bytes[start..<(start + 127)].reduce(0, { $0 + Int($1) }) % 256) % 256)
        }
        return Data(bytes)
    }
    func testIdentityAndLosslessOverride() throws {
        let data = fixture(extensions: 1)
        let document = try EDIDDocument(data: data)
        XCTAssertEqual(document.manufacturer, "ABC")
        XCTAssertEqual(document.productID, 0x1234)
        XCTAssertEqual(document.serialNumber, 0x5678)
        XCTAssertEqual(document.displayName, "Test Monitor")
        let plist = try PropertyListSerialization.propertyList(from: document.overridePropertyList(), format: nil) as! [String: Any]
        XCTAssertEqual(plist["IODisplayEDID"] as? Data, data)
    }
    func testRejectsCorruptionAndTruncation() {
        var damaged = fixture(); damaged[20] ^= 1
        XCTAssertThrowsError(try EDIDDocument(data: damaged)) { XCTAssertEqual($0 as? EDIDError, .checksum(block: 0)) }
        XCTAssertThrowsError(try EDIDDocument(data: fixture().prefix(127)))
        XCTAssertThrowsError(try EDIDDocument(data: fixture(extensions: 1).prefix(128))) {
            XCTAssertEqual($0 as? EDIDError, .extensionCountMismatch)
        }
    }
    func testExtensionChecksumAndInvalidManufacturer() {
        var extensionDamage = fixture(extensions: 1); extensionDamage[128] = 1
        XCTAssertThrowsError(try EDIDDocument(data: extensionDamage)) {
            XCTAssertEqual($0 as? EDIDError, .checksum(block: 1))
        }
        var badVendor = fixture(); badVendor[8] = 0; badVendor[9] = 0
        badVendor[127] = UInt8((256 - badVendor.prefix(127).reduce(0, { $0 + Int($1) }) % 256) % 256)
        XCTAssertThrowsError(try EDIDDocument(data: badVendor)) {
            XCTAssertEqual($0 as? EDIDError, .invalidManufacturer)
        }
    }
    func testEveryLengthBoundaryAndHeader() throws {
        for length in [0, 1, 127, 129, 32769, 32896] {
            XCTAssertThrowsError(try EDIDDocument(data: Data(repeating: 0, count: length))) {
                XCTAssertEqual($0 as? EDIDError, .invalidLength)
            }
        }
        var badHeader = fixture(); badHeader[0] = 1
        XCTAssertThrowsError(try EDIDDocument(data: badHeader)) {
            XCTAssertEqual($0 as? EDIDError, .invalidHeader)
        }
        let maximum = fixture(extensions: 255)
        XCTAssertEqual(try EDIDDocument(data: maximum).extensionCount, 255)
        let document = try EDIDDocument(data: maximum)
        let plist = try PropertyListSerialization.propertyList(from: document.overridePropertyList(), format: nil) as! [String: Any]
        XCTAssertEqual(plist["IODisplayEDID"] as? Data, maximum)
        XCTAssertEqual(plist["DisplayVendorID"] as? Int, 1091)
        XCTAssertEqual(plist["DisplayProductID"] as? Int, 0x1234)
    }
    func testPlansRoundTripBoundariesAndRussianRecovery() throws {
        for dimensions in [(1, 1), (8192, 8192), (1920, 1080)] {
            let plan = try HiDPIConfigurationPlan(width: dimensions.0, height: dimensions.1)
            XCTAssertEqual(plan.pixelWidth, dimensions.0 * 2)
            XCTAssertEqual(plan.pixelHeight, dimensions.1 * 2)
            let data = try JSONEncoder().encode(plan)
            XCTAssertEqual(try JSONDecoder().decode(HiDPIConfigurationPlan.self, from: data), plan)
            XCTAssertEqual(plan.recoverySteps.count, 4)
            XCTAssertTrue(plan.recoverySteps[1].contains("резервную копию"))
            XCTAssertTrue(plan.recoverySteps[2].contains("безопасный режим"))
            XCTAssertTrue(plan.recoverySteps[3].contains("только новую"))
            XCTAssertTrue(plan.installationStatus.contains("Только план"))
        }
        for dimensions in [(-1, 1), (1, 0), (8193, 1), (1, 8193), (Int.max, Int.max)] {
            XCTAssertThrowsError(try HiDPIConfigurationPlan(width: dimensions.0, height: dimensions.1))
        }
        for error in [EDIDError.invalidLength, .invalidHeader, .extensionCountMismatch, .checksum(block: 0), .invalidManufacturer] {
            XCTAssertNotNil(error.errorDescription)
        }
        XCTAssertTrue(HiDPIPlanError.invalidDimensions.localizedDescription.contains("положительными"))
        XCTAssertTrue(HiDPIPlanError.exceedsLimit.localizedDescription.contains("8192"))
    }
    func testPlanValidatesBeforeMultiplication() throws {
        let plan = try HiDPIConfigurationPlan(width: 1920, height: 1080)
        XCTAssertEqual(plan.pixelWidth, 3840)
        XCTAssertEqual(plan.pixelHeight, 2160)
        XCTAssertThrowsError(try HiDPIConfigurationPlan(width: Int.max, height: 1))
        XCTAssertThrowsError(try HiDPIConfigurationPlan(width: 0, height: 1080))
    }
}
