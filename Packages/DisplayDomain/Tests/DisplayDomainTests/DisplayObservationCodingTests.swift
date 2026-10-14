import XCTest
@testable import DisplayDomain

/// `DisplayObservation` spells out its CodingKeys (to keep HDR under its historical key), so a new
/// stored field left out of them would compile and silently never persist. This is the tripwire.
final class DisplayObservationCodingTests: XCTestCase {
    private func populated() -> DisplayObservation {
        DisplayObservation(
            recordID: .init(rawValue: "cg:A"), cgDisplayID: 7, cgUUID: "UUID-A", ioServicePath: "IOService:/x",
            isActive: true, overlay: .dimmed, origin: .init(x: -1920, y: 40),
            mode: DisplayMode(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080,
                              refreshHz: 59.94, isHiDPI: true, bitDepth: 10),
            rotation: .degrees90, isMain: true, mirrorSourceID: .init(rawValue: "cg:B"), hdrEnabled: true,
            colorProfileName: "Display P3", transport: .hdmi, displayClass: .external,
            physicalPresence: .physical, generation: .init(3), observedAt: Date(timeIntervalSince1970: 1_000))
    }

    func testEveryStoredFieldSurvivesCoding() throws {
        let observation = populated()
        let data = try JSONEncoder().encode(observation)
        XCTAssertEqual(try JSONDecoder().decode(DisplayObservation.self, from: data), observation)
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        for label in Mirror(reflecting: observation).children.compactMap(\.label) {
            let key = label == "hdrReported" ? "hdrEnabled" : label
            XCTAssertTrue(keys.contains(key), "\(label) is not persisted — add it to DisplayObservation.CodingKeys "
                          + "(and give it a value in this fixture)")
        }
    }
}
