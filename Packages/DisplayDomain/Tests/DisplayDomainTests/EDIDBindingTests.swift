import XCTest
@testable import DisplayDomain

/// SD-01 / TR-05: a live EDID read must return *this* display's bytes or say it can't, never the
/// first blob that shares a product code.
final class EDIDBindingTests: XCTestCase {
    /// "DEL" as the big-endian manufacturer word Core Graphics reports (`CGDisplayVendorNumber`).
    private let dell: UInt32 = 0x10AC

    /// A minimal valid base block: header, identity fields, a variable byte (week) to make two
    /// otherwise-identical units differ, and a fixed checksum.
    private func edid(vendor: UInt16 = 0x10AC, product: UInt16 = 0xA0B1, serial: UInt32,
                      week: UInt8 = 12) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 128)
        b.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        b[8] = UInt8(vendor >> 8); b[9] = UInt8(vendor & 0xFF)
        b[10] = UInt8(product & 0xFF); b[11] = UInt8(product >> 8)
        b[12] = UInt8(serial & 0xFF); b[13] = UInt8((serial >> 8) & 0xFF)
        b[14] = UInt8((serial >> 16) & 0xFF); b[15] = UInt8((serial >> 24) & 0xFF)
        b[16] = week; b[17] = 33; b[18] = 1; b[19] = 4
        let sum = b[0..<127].reduce(0) { $0 + Int($1) }
        b[127] = UInt8((256 - sum % 256) % 256)
        return b
    }

    private func target(product: UInt32 = 0xA0B1, serial: UInt32) -> EDIDBinding.Target {
        EDIDBinding.Target(vendorNumber: dell, modelNumber: product, serialNumber: serial)
    }

    /// The reported defect: two same-model monitors, and a lookup for the second one. Matching the
    /// product code first handed back the first monitor's bytes.
    func testIdenticalModelsWithDifferentSerialsEachGetTheirOwnBytes() {
        let left = edid(serial: 1001), right = edid(serial: 2002)
        XCTAssertEqual(EDIDBinding.bind([left, right], to: target(serial: 2002)), .matched(right))
        XCTAssertEqual(EDIDBinding.bind([left, right], to: target(serial: 1001)), .matched(left))
        XCTAssertEqual(EDIDBinding.bind([right, left], to: target(serial: 2002)), .matched(right),
                       "registry order must not decide")
    }

    func testIdenticalModelsWithoutSerialsAreAmbiguous() {
        let first = edid(serial: 0, week: 12), second = edid(serial: 0, week: 30)
        XCTAssertEqual(EDIDBinding.bind([first, second], to: target(serial: 0)), .ambiguous(candidates: 2))
    }

    /// The same blob published on two registry nodes is one answer, not an ambiguity.
    func testTheSameBlobOnSeveralNodesIsOneCandidate() {
        let blob = edid(serial: 0)
        XCTAssertEqual(EDIDBinding.bind([blob, blob], to: target(serial: 0)), .matched(blob))
    }

    /// The old fallbacks ("a single candidate is unambiguous", "first non-Apple blob") returned
    /// another display's EDID for a display whose own isn't exposed.
    func testAnotherDisplaysBlobIsNeverTheAnswer() {
        let other = edid(product: 0x0042, serial: 77)
        XCTAssertEqual(EDIDBinding.bind([other], to: target(serial: 1001)), .notFound)
        let sameModelOtherUnit = edid(serial: 77)
        XCTAssertEqual(EDIDBinding.bind([sameModelOtherUnit], to: target(serial: 1001)), .notFound)
    }

    func testAVendorMismatchIsNotAMatch() {
        let samsungSameNumbers = edid(vendor: 0x4C2D, serial: 1001)
        XCTAssertEqual(EDIDBinding.bind([samsungSameNumbers], to: target(serial: 1001)), .notFound)
    }

    func testADisplayCoreGraphicsCantIdentifyGetsNoBytes() {
        let only = edid(serial: 1001)
        XCTAssertEqual(EDIDBinding.bind([only], to: EDIDBinding.Target(
            vendorNumber: 0, modelNumber: 0xA0B1, serialNumber: 1001)), .unidentifiedTarget)
        XCTAssertEqual(EDIDBinding.bind([only], to: EDIDBinding.Target(
            vendorNumber: dell, modelNumber: 0xFFFF_FFFF, serialNumber: 1001)), .unidentifiedTarget)
    }

    func testMalformedBlobsAreIgnored() {
        var broken = edid(serial: 1001)
        broken[0] = 0x12  // bad header
        let good = edid(serial: 1001, week: 40)
        XCTAssertEqual(EDIDBinding.bind([broken, good], to: target(serial: 1001)), .matched(good))
        XCTAssertEqual(EDIDBinding.bind([broken], to: target(serial: 1001)), .notFound)
        XCTAssertEqual(EDIDBinding.bind([], to: target(serial: 1001)), .notFound)
    }
}
