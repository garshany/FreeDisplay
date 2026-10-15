import AutomationSchema
import XCTest
@testable import TopologyCore

/// IN-16: a receiver app reads, takes over and gives back the feedback settings; the user's own
/// choices are restored, and newer user changes are never overwritten.
final class OSDReceiverHandshakeTests: XCTestCase {
    private func enabled(_ change: (inout OpenDisplaySettings) -> Void = { _ in }) -> OpenDisplaySettings {
        var settings = OpenDisplaySettings.default
        settings.osdFeedback.receiverHandshakeEnabled = true
        change(&settings)
        return settings
    }

    private func send(_ command: OSDSettingsHandshake.Command, receiver: String? = "Notch HUD",
                      hideBasic: Bool? = nil, hideCustom: Bool? = nil, uuid: String = "u1",
                      to settings: inout OpenDisplaySettings) -> OSDSettingsHandshake.Response {
        OSDReceiverHandshake.handle(.request(.init(command: command, uuid: uuid, receiver: receiver,
                                                   hideBasic: hideBasic, hideCustom: hideCustom)),
                                    settings: &settings)
    }

    func testDisabledAnswersWithoutSettingsAndChangesNothing() {
        var settings = OpenDisplaySettings.default
        let before = settings
        for command in [OSDSettingsHandshake.Command.get, .claim, .release] {
            let response = send(command, to: &settings)
            XCTAssertEqual(response.result, .disabled)
            XCTAssertEqual(response.uuid, "u1")
            XCTAssertNil(response.showsBasic)
            XCTAssertNil(response.publishing)
        }
        XCTAssertEqual(settings, before)
    }

    func testGetReportsTheCurrentState() {
        var settings = enabled()
        let response = send(.get, to: &settings)
        XCTAssertEqual(response.result, .ok)
        XCTAssertEqual(response.showsBasic, true)
        XCTAssertEqual(response.showsCustom, true)
        XCTAssertEqual(response.publishing, false)
        XCTAssertNil(response.claimedBy)
    }

    func testClaimPublishesHidesTheBasicHUDAndReleaseRestores() {
        var settings = enabled()
        let original = settings
        let claimed = send(.claim, to: &settings)
        XCTAssertEqual(claimed.result, .ok)
        XCTAssertEqual(claimed.claimedBy, "Notch HUD")
        XCTAssertTrue(settings.publishOSDEventsEnabled)
        XCTAssertFalse(settings.osdEnabled)
        XCTAssertTrue(settings.osdFeedback.showsCustomFeedback, "custom feedback is kept unless asked")
        XCTAssertEqual(settings.osdStyle, original.osdStyle, "the style stays the user's own choice")

        XCTAssertEqual(send(.release, to: &settings).result, .ok)
        XCTAssertEqual(settings, original)
    }

    func testClaimCanHideCustomFeedbackAndKeepTheBasicHUD() {
        var settings = enabled()
        _ = send(.claim, hideBasic: false, hideCustom: true, to: &settings)
        XCTAssertTrue(settings.osdEnabled)
        XCTAssertFalse(settings.osdFeedback.showsCustomFeedback)
        OSDReceiverHandshake.release(&settings)
        XCTAssertTrue(settings.osdFeedback.showsCustomFeedback)
    }

    func testAUserChangeMadeDuringTheClaimSurvivesTheRelease() {
        var settings = enabled()
        _ = send(.claim, to: &settings)
        // The user turns OpenDisplay's own HUD back on while the receiver holds the settings.
        settings.osdEnabled = true
        OSDReceiverHandshake.release(&settings)
        XCTAssertTrue(settings.osdEnabled)
        XCTAssertFalse(settings.publishOSDEventsEnabled, "untouched fields still come back")
        XCTAssertNil(settings.osdFeedback.receiverClaim)
    }

    func testASecondClaimKeepsTheFirstSnapshot() {
        var settings = enabled()
        _ = send(.claim, to: &settings)
        _ = send(.claim, hideCustom: true, to: &settings)
        XCTAssertFalse(settings.osdFeedback.showsCustomFeedback)
        XCTAssertEqual(settings.osdFeedback.receiverClaim?.prior,
                       .init(showsBasicFeedback: true, showsCustomFeedback: true, publishing: false))
        OSDReceiverHandshake.release(&settings)
        XCTAssertTrue(settings.osdEnabled)
        XCTAssertTrue(settings.osdFeedback.showsCustomFeedback)
        XCTAssertFalse(settings.publishOSDEventsEnabled)
    }

    func testAnotherReceiverIsRefusedAndCannotRelease() {
        var settings = enabled()
        _ = send(.claim, to: &settings)
        let held = settings
        let refused = send(.claim, receiver: "Other", to: &settings)
        XCTAssertEqual(refused.result, .refused)
        XCTAssertEqual(refused.claimedBy, "Notch HUD")
        XCTAssertEqual(send(.release, receiver: "Other", to: &settings).result, .notClaimed)
        XCTAssertEqual(settings, held)
    }

    func testReleaseWithoutAClaimChangesNothing() {
        var settings = enabled()
        let before = settings
        XCTAssertEqual(send(.release, to: &settings).result, .notClaimed)
        XCTAssertEqual(settings, before)
    }

    func testMalformedRequestsChangeNothing() {
        var settings = enabled()
        let before = settings
        XCTAssertEqual(OSDReceiverHandshake.handle(.malformed(uuid: "x"), settings: &settings).result, .malformed)
        XCTAssertEqual(send(.claim, receiver: nil, to: &settings).result, .malformed)
        XCTAssertEqual(send(.claim, receiver: " \n\t ", to: &settings).result, .malformed)
        XCTAssertEqual(settings, before)
    }

    func testReceiverNamesAreShownAsPlainSingleLineText() {
        XCTAssertEqual(OSDReceiverHandshake.displayName("  Notch\nHUD\u{1B}[31m "), "Notch HUD [31m")
        XCTAssertNil(OSDReceiverHandshake.displayName("\n"))
        XCTAssertNil(OSDReceiverHandshake.displayName(nil))
    }

    func testDecodedWireRequestIsHandled() {
        var settings = enabled()
        let wire = #"{"command":"claim","receiver":"Notch HUD","uuid":"abc"}"#
        let response = OSDReceiverHandshake.handle(OSDSettingsHandshake.decode(wire), settings: &settings)
        XCTAssertEqual(response.result, .ok)
        XCTAssertEqual(response.uuid, "abc")
        XCTAssertEqual(OSDSettingsHandshake.Response.decode(response.jsonString), response)
    }
}
