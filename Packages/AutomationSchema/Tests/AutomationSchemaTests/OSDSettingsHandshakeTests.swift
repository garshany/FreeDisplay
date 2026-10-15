import XCTest
@testable import AutomationSchema

/// IN-16: the handshake's wire format reads anything another process sends without trapping, and
/// keeps the uuid for matching whenever it can.
final class OSDSettingsHandshakeTests: XCTestCase {
    func testRequestRoundTrip() {
        let request = OSDSettingsHandshake.Request(command: .claim, uuid: "u", receiver: "Notch",
                                                   hideBasic: true, hideCustom: false)
        XCTAssertEqual(OSDSettingsHandshake.decode(request.jsonString), .request(request))
    }

    func testMinimalRequestHasNoOptionalFields() {
        guard case .request(let request) = OSDSettingsHandshake.decode(#"{"command":"get"}"#) else {
            return XCTFail("a bare get is a request")
        }
        XCTAssertEqual(request.command, .get)
        XCTAssertNil(request.uuid)
        XCTAssertNil(request.version)
        XCTAssertNil(request.hideBasic)
    }

    func testUnknownCommandIsMalformedButKeepsTheUUID() {
        XCTAssertEqual(OSDSettingsHandshake.decode(#"{"command":"wipe","uuid":"u7"}"#), .malformed(uuid: "u7"))
    }

    func testUnsupportedVersionCannotChangeSettings() {
        XCTAssertEqual(OSDSettingsHandshake.decode(#"{"version":2,"command":"claim","receiver":"HUD","uuid":"v2"}"#),
                       .malformed(uuid: "v2"))
    }

    func testGarbageIsMalformed() {
        XCTAssertEqual(OSDSettingsHandshake.decode("not json"), .malformed(uuid: nil))
        XCTAssertEqual(OSDSettingsHandshake.decode(#"["command","get"]"#), .malformed(uuid: nil))
        XCTAssertEqual(OSDSettingsHandshake.decode(nil), .malformed(uuid: nil))
        XCTAssertEqual(OSDSettingsHandshake.decode(42), .malformed(uuid: nil))
        XCTAssertEqual(OSDSettingsHandshake.decode(#"{"command":"get","uuid":7}"#), .malformed(uuid: nil))
    }

    func testResponseRoundTripAndVersion() {
        let response = OSDSettingsHandshake.Response(result: .ok, uuid: "u", showsBasic: false, showsCustom: true,
                                                     publishing: true, claimedBy: "Notch")
        XCTAssertEqual(response.version, OSDSettingsHandshake.schemaVersion)
        XCTAssertEqual(OSDSettingsHandshake.Response.decode(response.jsonString), response)
        XCTAssertNil(OSDSettingsHandshake.Response.decode("{"))
    }

    func testNamesAreFreeDisplaysOwn() {
        XCTAssertTrue(OSDSettingsHandshake.requestNotificationName.hasPrefix("dev.opendisplay."))
        XCTAssertTrue(OSDSettingsHandshake.responseNotificationName.hasPrefix("dev.opendisplay."))
        XCTAssertNotEqual(OSDSettingsHandshake.requestNotificationName, OSDBroadcast.notificationName)
    }
}
