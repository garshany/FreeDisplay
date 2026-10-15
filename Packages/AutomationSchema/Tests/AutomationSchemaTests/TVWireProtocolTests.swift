import Foundation
import XCTest
@testable import AutomationSchema

final class TVWireProtocolTests: XCTestCase {
    private func object(_ text: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    func testLGRegistrationUsesOwnUnsignedManifestAndOptionalClientKey() throws {
        let value = try object(TVWireProtocol.lgRegister(clientKey: "fake", requirePIN: true, id: "pair"))
        XCTAssertEqual(value["type"] as? String, "register")
        let payload = value["payload"] as! [String: Any]
        XCTAssertEqual(payload["client-key"] as? String, "fake")
        XCTAssertEqual(payload["pairingType"] as? String, "PIN")
        let manifest = payload["manifest"] as! [String: Any]
        XCTAssertNil(manifest["signatures"])
        XCTAssertTrue((manifest["permissions"] as! [String]).contains("CONTROL_AUDIO"))
        let prompt = try object(TVWireProtocol.lgRegister(clientKey: nil, requirePIN: false, id: "next"))
        XCTAssertNil((prompt["payload"] as! [String: Any])["client-key"])
    }

    func testLGMessagesUseProtocolSpecificAddressingAndDoNotEmitServiceActions() throws {
        let cases: [(TVAction, String)] = [(.volumeUp, "ssap://audio/volumeUp"), (.volumeDown, "ssap://audio/volumeDown"),
            (.powerOff, "ssap://system/turnOff"), (.refreshInputs, "ssap://tv/getExternalInputList"),
            (.switchInput("HDMI_1"), "ssap://tv/switchInput")]
        for (action, uri) in cases {
            let value = try object(TVWireProtocol.lgMessage(action, id: "request"))
            XCTAssertEqual(value["uri"] as? String, uri)
            XCTAssertEqual(value["id"] as? String, "request")
            XCTAssertEqual(value["type"] as? String, "request")
        }
        XCTAssertThrowsError(try TVWireProtocol.lgMessage(.source, id: "x"))
        XCTAssertThrowsError(try TVWireProtocol.lgMessage(.muteToggle, id: "x"))
    }

    func testLGOnlyAcceptsCorrelatedRegistrationAndRetainsInputIdentity() throws {
        XCTAssertEqual(try TVWireProtocol.parse("{\"type\":\"registered\",\"id\":\"old\",\"payload\":{\"client-key\":\"secret\"}}", family: .lgWebOS, registrationID: "current"), .ignored)
        let inputs = "{\"type\":\"response\",\"id\":\"inputs\",\"payload\":{\"returnValue\":true,\"devices\":[{\"id\":\"HDMI_1\",\"label\":\"Игровой Mac\",\"connected\":true}]}}"
        XCTAssertEqual(try TVWireProtocol.parse(inputs, family: .lgWebOS, registrationID: "pair"),
            .reply(id: "inputs", success: true, muted: nil, inputs: [TVInput(id: "HDMI_1", label: "Игровой Mac", connected: true)]))
    }

    func testMalformedAndDuplicateInputMessagesAreRefused() throws {
        for text in ["[]", "not JSON", "{\"type\":\"registered\",\"id\":\"pair\",\"payload\":{}}",
                     "{\"type\":\"response\",\"id\":\"x\",\"payload\":{\"devices\":[{\"id\":\"A\"},{\"id\":\"A\"}]}}"] {
            XCTAssertThrowsError(try TVWireProtocol.parse(text, family: .lgWebOS, registrationID: "pair"))
        }
    }

    func testMissingReturnValueIsNotSuccessfulAndDeniedKeysAreReplies() throws {
        XCTAssertEqual(try TVWireProtocol.parse("{\"type\":\"response\",\"id\":\"x\",\"payload\":{}}", family: .lgWebOS, registrationID: "pair"), .reply(id: "x", success: false, muted: nil, inputs: nil))
        XCTAssertEqual(try TVWireProtocol.parse("{\"type\":\"error\",\"id\":\"key\",\"error\":\"403 denied\"}", family: .lgWebOS, registrationID: "pair"), .reply(id: "key", success: false, muted: nil, inputs: nil))
    }

    func testSamsungKeysAreRelativeAndSourceIsNotADirectInputList() throws {
        let cases: [(TVAction, String)] = [(.volumeUp, "KEY_VOLUP"), (.volumeDown, "KEY_VOLDOWN"),
            (.muteToggle, "KEY_MUTE"), (.source, "KEY_SOURCE"), (.hdmi, "KEY_HDMI"), (.powerOff, "KEY_POWEROFF")]
        for (action, key) in cases {
            let value = try object(TVWireProtocol.samsungMessage(action))
            XCTAssertEqual(value["method"] as? String, "ms.remote.control")
            let params = value["params"] as! [String: Any]
            XCTAssertEqual(params["DataOfCmd"] as? String, key)
            XCTAssertEqual(params["Cmd"] as? String, "Click")
            XCTAssertEqual(params["TypeOfRemote"] as? String, "SendRemoteKey")
        }
        XCTAssertThrowsError(try TVWireProtocol.samsungMessage(.switchInput("HDMI_1")))
        XCTAssertThrowsError(try TVWireProtocol.samsungMessage(.refreshInputs))
    }

    func testSamsungTokenIsOptionalButNeverReadFromAnotherFamily() throws {
        let event = "{\"event\":\"ms.channel.connect\",\"data\":{\"token\":\"fake\"}}"
        XCTAssertEqual(try TVWireProtocol.parse(event, family: .samsungTizen, registrationID: "pair"), .authorized("fake"))
        XCTAssertEqual(try TVWireProtocol.parse(event, family: .lgWebOS, registrationID: "pair"), .ignored)
        XCTAssertEqual(try TVWireProtocol.parse("{\"event\":\"ms.channel.connect\"}", family: .samsungTizen, registrationID: "pair"), .authorized(nil))
        XCTAssertEqual(try TVWireProtocol.parse("{\"event\":\"ms.channel.unauthorized\"}", family: .samsungTizen, registrationID: "pair"), .authorizationDenied)
    }

    func testSamsungURLKeepsSecretsOutOfConfigurationAndEncodesToken() throws {
        let endpoint = try TVEndpoint(host: "tv.invalid", port: 8002, tls: true)
        let url = endpoint.url(family: .samsungTizen, token: "fake&next=?")
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.scheme, "wss")
        XCTAssertEqual(parts.path, "/api/v2/channels/samsung.remote.control")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "token" })?.value, "fake&next=?")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "name" })?.value, Data("FreeDisplay".utf8).base64EncodedString())
        let json = String(decoding: try JSONEncoder().encode(endpoint), as: UTF8.self)
        XCTAssertFalse(json.contains("fake&next"))
    }

    func testMACMagicPacketMatchesWireFormatAndRoundTrips() throws {
        let mac = try TVMACAddress("02-11-22-33-44-55")
        XCTAssertEqual(mac.magicPacket.count, 102)
        XCTAssertEqual(Array(mac.magicPacket.prefix(6)), Array(repeating: 255, count: 6))
        for offset in stride(from: 6, to: 102, by: 6) {
            XCTAssertEqual(Array(mac.magicPacket[offset..<(offset + 6)]), [2, 17, 34, 51, 68, 85])
        }
        XCTAssertEqual(try JSONDecoder().decode(TVMACAddress.self, from: JSONEncoder().encode(mac)), mac)
        for text in ["", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff", "01:11:22:33:44:55", "02:11:22:33:44", "02:11:22:33:44:GG"] {
            XCTAssertThrowsError(try TVMACAddress(text))
        }
    }

    func testEndpointAndDeadlineDecodeEnforceConstructorInvariants() throws {
        for host in ["", "user@host", "host/path", "host?x", "host\nheader", "host name"] {
            XCTAssertThrowsError(try TVEndpoint(host: host, port: 8002, tls: true))
        }
        XCTAssertThrowsError(try TVEndpoint(host: "tv.invalid", port: 0, tls: true))
        XCTAssertThrowsError(try JSONDecoder().decode(TVEndpoint.self, from: Data("{\"host\":\"tv.invalid\",\"port\":0,\"tls\":true}".utf8)))
        for value in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertThrowsError(try TVDeadlines(connection: value, response: 1, sessionLifetime: 2))
            XCTAssertThrowsError(try TVDeadlines(connection: 1, response: value, sessionLifetime: 2))
            XCTAssertThrowsError(try TVDeadlines(connection: 1, response: 2, sessionLifetime: value))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(TVDeadlines.self, from: Data("{\"connection\":0,\"response\":1,\"sessionLifetime\":2}".utf8)))
    }

    func testCertificatePinNormalizesOnlyAnExactSHA256Digest() throws {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(try TVCertificatePin(hex.uppercased()).hex, hex)
        XCTAssertEqual(try TVCertificatePin(Array(repeating: "AB", count: 32).joined(separator: ":")).hex, hex)
        for invalid in ["", "abcd", String(repeating: "zz", count: 32), hex + "ab"] {
            XCTAssertThrowsError(try TVCertificatePin(invalid))
        }
    }

    func testStaleGenerationCannotEnableKeysOrPublishOldInput() {
        var state = TVSessionState()
        let old = state.reset(to: .connecting, paired: false)
        let current = state.reset(to: .configured, paired: false)
        state.transition(.ready, generation: old, paired: true)
        state.record(TVCommandReceipt(.acknowledged), action: .switchInput("HDMI_1"), generation: old)
        XCTAssertEqual(state.generation, current)
        XCTAssertEqual(state.connection, .configured)
        XCTAssertFalse(state.paired)
        XCTAssertNil(state.requestedInput)
        XCTAssertTrue(state.featureOutcomes.isEmpty)
    }

    func testPINBuilderRejectsNonDigitsWithoutChoosingAPINLength() throws {
        for pin in ["", "1x", "12\n34", "１２３４"] { XCTAssertThrowsError(try TVWireProtocol.lgPIN(pin, id: "pin")) }
        XCTAssertNoThrow(try TVWireProtocol.lgPIN("1234567890123456789", id: "pin"))
    }

    func testPinExceptionIsScopedToOneDeviceEndpointAndCannotAcceptAnotherCertificate() throws {
        let endpoint = try TVEndpoint(host: "tv.invalid", port: 3001, tls: true)
        let pin = String(repeating: "ab", count: 32)
        XCTAssertTrue(TVCertificateTrustPolicy.permitsPinnedLeaf(endpoint: endpoint, approvedPin: pin,
            challengeHost: "TV.INVALID", challengePort: 3001, leafSHA256: pin))
        for (host, port, digest) in [("other.invalid", 3001, pin), ("tv.invalid", 8002, pin),
                                    ("tv.invalid", 3001, String(repeating: "cd", count: 32)), ("tv.invalid", 3001, "invalid")] {
            XCTAssertFalse(TVCertificateTrustPolicy.permitsPinnedLeaf(endpoint: endpoint, approvedPin: pin,
                challengeHost: host, challengePort: port, leafSHA256: digest))
        }
        XCTAssertFalse(TVCertificateTrustPolicy.permitsPinnedLeaf(endpoint: endpoint, approvedPin: "invalid",
            challengeHost: "tv.invalid", challengePort: 3001, leafSHA256: pin))
        XCTAssertFalse(TVCertificateTrustPolicy.permitsPinnedLeaf(endpoint: try TVEndpoint(host: "tv.invalid", port: 3001, tls: false),
            approvedPin: pin, challengeHost: "tv.invalid", challengePort: 3001, leafSHA256: pin))
    }
}
