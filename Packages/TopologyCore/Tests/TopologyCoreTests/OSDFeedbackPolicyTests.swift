import XCTest
@testable import TopologyCore

final class OSDFeedbackPolicyTests: XCTestCase {
    private func settings(osd: Bool = true, style: OSDStyle = .native, publish: Bool = false) -> OpenDisplaySettings {
        var settings = OpenDisplaySettings.default
        settings.osdEnabled = osd
        settings.osdStyle = style
        settings.publishOSDEventsEnabled = publish
        return settings
    }

    func testPublishingDoesNotDependOnTheLocalHUD() {
        // IN-04: a slider change (no local HUD wanted) is still published when broadcasting is on…
        XCTAssertEqual(OSDFeedbackPolicy.route(localHUDWanted: false, settings: settings(publish: true)),
                       .init(drawsLocalHUD: false, publishesEvent: true))
        // …and so is a key press with the local HUD switched off entirely.
        XCTAssertEqual(OSDFeedbackPolicy.route(localHUDWanted: true, settings: settings(osd: false, publish: true)),
                       .init(drawsLocalHUD: false, publishesEvent: true))
    }

    func testDisabledBroadcastingPublishesNothing() {
        for wanted in [true, false] {
            XCTAssertFalse(OSDFeedbackPolicy.route(localHUDWanted: wanted, settings: settings()).publishesEvent)
        }
    }

    func testLocalHUDOnlyForWantedOriginsWithAnAppDrawnStyle() {
        XCTAssertTrue(OSDFeedbackPolicy.route(localHUDWanted: true, settings: settings()).drawsLocalHUD)
        XCTAssertFalse(OSDFeedbackPolicy.route(localHUDWanted: false, settings: settings()).drawsLocalHUD)
        XCTAssertFalse(OSDFeedbackPolicy.route(localHUDWanted: true,
                                               settings: settings(style: .external, publish: true)).drawsLocalHUD)
    }

    func testExternalOnlyWithBroadcastingOffIsFlagged() {
        XCTAssertTrue(OSDFeedbackPolicy.externalOnlyDeliversNothing(settings(style: .external)))
        XCTAssertFalse(OSDFeedbackPolicy.externalOnlyDeliversNothing(settings(style: .external, publish: true)))
        XCTAssertFalse(OSDFeedbackPolicy.externalOnlyDeliversNothing(settings(style: .native)))
        // With the HUD switched off the style isn't in play, so nothing is promised.
        XCTAssertFalse(OSDFeedbackPolicy.externalOnlyDeliversNothing(settings(osd: false, style: .external)))
    }
}
