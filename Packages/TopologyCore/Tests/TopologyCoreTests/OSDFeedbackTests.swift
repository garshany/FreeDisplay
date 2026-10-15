import AutomationSchema
import DisplayDomain
import XCTest
@testable import TopologyCore

/// SO-35 / TR-17 / IN-16: the feedback switches, screen choice, placement, interaction and the
/// delivery state Settings reports.
final class OSDFeedbackTests: XCTestCase {
    private func settings(_ change: (inout OpenDisplaySettings) -> Void = { _ in }) -> OpenDisplaySettings {
        var settings = OpenDisplaySettings.default
        change(&settings)
        return settings
    }

    private func draws(_ kind: OSDContent.Kind, display: String? = "d1", wanted: Bool = true, menuOpen: Bool = false,
                       _ settings: OpenDisplaySettings) -> Bool {
        OSDFeedbackPolicy.route(.init(kind: kind, displayID: display, localHUDWanted: wanted, menuOpen: menuOpen),
                                settings: settings).drawsLocalHUD
    }

    // MARK: Switches

    func testBasicAndCustomSwitchesAreIndependent() {
        let basicOff = settings { $0.osdEnabled = false }
        XCTAssertFalse(draws(.brightness, basicOff))
        XCTAssertFalse(draws(.volume, basicOff))
        XCTAssertFalse(draws(.mute, basicOff))
        XCTAssertTrue(draws(.input, basicOff), "custom feedback keeps its own switch")

        let customOff = settings { $0.osdFeedback.showsCustomFeedback = false }
        XCTAssertTrue(draws(.brightness, customOff))
        XCTAssertFalse(draws(.input, customOff))
    }

    func testExternalOnlyHidesEveryLocalHUD() {
        let external = settings { $0.osdStyle = .external; $0.publishOSDEventsEnabled = true }
        for kind in [OSDContent.Kind.brightness, .volume, .mute, .input] {
            XCTAssertFalse(draws(kind, external), "\(kind)")
        }
    }

    func testPerDisplayVolumeSwitchCoversMuteAndOnlyThatDisplay() {
        let hidden = settings { $0.osdFeedback.volumeHiddenDisplayIDs = ["d1"]; $0.publishOSDEventsEnabled = true }
        XCTAssertFalse(draws(.volume, display: "d1", hidden))
        XCTAssertFalse(draws(.mute, display: "d1", hidden))
        XCTAssertTrue(draws(.brightness, display: "d1", hidden), "brightness has no per-display switch")
        XCTAssertTrue(draws(.volume, display: "d2", hidden))
        // The change is still published: the switch is about OpenDisplay's HUD only.
        XCTAssertTrue(OSDFeedbackPolicy.route(.init(kind: .volume, displayID: "d1", localHUDWanted: true),
                                              settings: hidden).publishesEvent)
    }

    func testOpenMenuSuppressesOnlyMenuBarPlacements() {
        for position in OSDPosition.allCases {
            let placed = settings { $0.osdPosition = position; $0.publishOSDEventsEnabled = true }
            XCTAssertEqual(draws(.brightness, menuOpen: true, placed), !position.isMenuBarAnchored, "\(position)")
            XCTAssertTrue(draws(.brightness, menuOpen: false, placed), "\(position)")
            XCTAssertTrue(OSDFeedbackPolicy.route(.init(kind: .brightness, localHUDWanted: true, menuOpen: true),
                                                  settings: placed).publishesEvent,
                          "an open menu never stops the event")
        }
        XCTAssertEqual(Set(OSDPosition.allCases.filter(\.isMenuBarAnchored)), [.underMenuBarIcon, .underMenuBar, .topTrailing])
    }

    func testOriginThatAsksForNoHUDDrawsNone() {
        XCTAssertFalse(draws(.brightness, wanted: false, settings()))
    }

    // MARK: Delivery state

    func testDeliveryStates() {
        XCTAssertEqual(OSDFeedbackPolicy.delivery(settings()), .localOnly)
        XCTAssertEqual(OSDFeedbackPolicy.delivery(settings { $0.publishOSDEventsEnabled = true }), .localAndPublished)
        XCTAssertEqual(OSDFeedbackPolicy.delivery(settings { $0.osdStyle = .external }), .externalOnlyWithoutDispatch)
        XCTAssertEqual(OSDFeedbackPolicy.delivery(settings { $0.osdStyle = .external; $0.publishOSDEventsEnabled = true }),
                       .externalOnly)
        let allOff = settings { $0.osdEnabled = false; $0.osdFeedback.showsCustomFeedback = false }
        XCTAssertEqual(OSDFeedbackPolicy.delivery(allOff), .none)
        var publishing = allOff
        publishing.publishOSDEventsEnabled = true
        XCTAssertEqual(OSDFeedbackPolicy.delivery(publishing), .publishedOnly)
        // Custom feedback alone still draws locally — and still duplicates with a receiver.
        let customOnly = settings { $0.osdEnabled = false; $0.publishOSDEventsEnabled = true }
        XCTAssertEqual(OSDFeedbackPolicy.delivery(customOnly), .localAndPublished)
    }

    func testDeliveryAgreesWithTheExistingExternalOnlyFlag() {
        for style in OSDStyle.allCases {
            for enabled in [true, false] {
                for publish in [true, false] {
                    let s = settings { $0.osdStyle = style; $0.osdEnabled = enabled; $0.publishOSDEventsEnabled = publish }
                    XCTAssertEqual(OSDFeedbackPolicy.externalOnlyDeliversNothing(s),
                                   OSDFeedbackPolicy.delivery(s) == .externalOnlyWithoutDispatch)
                }
            }
        }
    }

    // MARK: Screen choice (TR-17)

    func testEachScreenChoicePicksItsOwnScreen() {
        // Pointer, focus and primary on three different screens; the change on a fourth.
        let available: [UInt32] = [1, 2, 3, 4]
        func pick(_ choice: OSDScreenChoice) -> UInt32? {
            OSDScreenPolicy.screen(position: .bottomCenter, choice: choice, affected: 4, pointer: 2, focused: 3,
                                   primary: 1, iconScreen: 1, available: available)
        }
        XCTAssertEqual(pick(.affectedDisplay), 4)
        XCTAssertEqual(pick(.pointer), 2)
        XCTAssertEqual(pick(.focused), 3)
        XCTAssertEqual(pick(.primary), 1, "always-primary shows on the primary even when another display changed")
    }

    func testAnAbsentChoiceFallsBackToThePrimaryThenAnyScreen() {
        // The affected display has no screen of its own (a mirror member): primary, not the pointer.
        XCTAssertEqual(OSDScreenPolicy.screen(position: .center, choice: .affectedDisplay, affected: 9, pointer: 2,
                                              focused: 3, primary: 1, iconScreen: nil, available: [1, 2, 3]), 1)
        XCTAssertEqual(OSDScreenPolicy.screen(position: .center, choice: .pointer, affected: nil, pointer: nil,
                                              focused: nil, primary: nil, iconScreen: nil, available: [5, 6]), 5)
        XCTAssertNil(OSDScreenPolicy.screen(position: .center, choice: .primary, affected: nil, pointer: nil,
                                            focused: nil, primary: 1, iconScreen: nil, available: []))
    }

    func testUnderTheIconFollowsTheIconNotTheChoice() {
        XCTAssertEqual(OSDScreenPolicy.screen(position: .underMenuBarIcon, choice: .affectedDisplay, affected: 2,
                                              pointer: 2, focused: 2, primary: 1, iconScreen: 3, available: [1, 2, 3]), 3)
        // No icon on screen (hidden by macOS): the user's screen choice decides.
        XCTAssertEqual(OSDScreenPolicy.screen(position: .underMenuBarIcon, choice: .affectedDisplay, affected: 2,
                                              pointer: 2, focused: 2, primary: 1, iconScreen: nil, available: [1, 2, 3]), 2)
    }

    // MARK: Layout

    private let screen = OSDFrame(x: 0, y: 0, width: 1000, height: 800)

    func testCentredPlacements() {
        let bottom = OSDLayout.origin(position: .bottomCenter, width: 200, height: 200, visibleFrame: screen,
                                      icon: nil, rightToLeft: false)
        XCTAssertEqual(bottom.x, 400); XCTAssertEqual(bottom.y, OSDLayout.bottomOffset)
        let top = OSDLayout.origin(position: .topCenter, width: 200, height: 200, visibleFrame: screen,
                                   icon: nil, rightToLeft: false)
        XCTAssertEqual(top.x, 400); XCTAssertEqual(top.y, 800 - 200 - OSDLayout.topOffset)
        let center = OSDLayout.origin(position: .center, width: 200, height: 100, visibleFrame: screen,
                                      icon: nil, rightToLeft: false)
        XCTAssertEqual(center.x, 400); XCTAssertEqual(center.y, 350)
    }

    func testTrailingCornerFollowsReadingDirection() {
        let ltr = OSDLayout.origin(position: .topTrailing, width: 240, height: 48, visibleFrame: screen,
                                   icon: nil, rightToLeft: false)
        XCTAssertEqual(ltr.x, 1000 - 240 - OSDLayout.edgeInset)
        XCTAssertEqual(ltr.y, 800 - 48 - OSDLayout.edgeInset)
        let rtl = OSDLayout.origin(position: .topTrailing, width: 240, height: 48, visibleFrame: screen,
                                   icon: nil, rightToLeft: true)
        XCTAssertEqual(rtl.x, OSDLayout.edgeInset)
    }

    func testUnderTheIconCentresBelowItAndStaysOnScreen() {
        let icon = OSDFrame(x: 600, y: 800, width: 30, height: 24)
        let under = OSDLayout.origin(position: .underMenuBarIcon, width: 240, height: 48, visibleFrame: screen,
                                     icon: icon, rightToLeft: false)
        XCTAssertEqual(under.x, 615 - 120)
        XCTAssertEqual(under.y, 800 - 48 - OSDLayout.menuBarGap)
        // An icon by the right edge: the HUD is pulled back fully onto the screen.
        let edge = OSDLayout.origin(position: .underMenuBarIcon, width: 240, height: 48, visibleFrame: screen,
                                    icon: OSDFrame(x: 985, y: 800, width: 15, height: 24), rightToLeft: false)
        XCTAssertEqual(edge.x, 1000 - 240 - OSDLayout.edgeInset)
        // No icon on this screen: the trailing corner stands in.
        let none = OSDLayout.origin(position: .underMenuBarIcon, width: 240, height: 48, visibleFrame: screen,
                                    icon: OSDFrame(x: 1500, y: 800, width: 30, height: 24), rightToLeft: false)
        XCTAssertEqual(none.x, 1000 - 240 - OSDLayout.edgeInset)
    }

    // MARK: Hover, drag and fade generations

    private let t0 = Date(timeIntervalSince1970: 100)

    func testAStationaryPointerUnderANewHUDDoesNotHoldIt() {
        var tracker = OSDHoldTracker(autoHide: 1.2)
        XCTAssertEqual(tracker.shown(now: t0, pointer: (50, 50)), .hide(at: t0.addingTimeInterval(1.2)))
        // An event at the same spot is the pointer resting there, not a deliberate hover.
        XCTAssertEqual(tracker.pointerMoved(to: (50, 50), inside: true, now: t0), .hide(at: t0.addingTimeInterval(1.2)))
        XCTAssertFalse(tracker.hovered)
    }

    func testDeliberateHoverHoldsUntilThePointerLeaves() {
        var tracker = OSDHoldTracker(autoHide: 1.2)
        _ = tracker.shown(now: t0, pointer: (50, 50))
        XCTAssertEqual(tracker.pointerMoved(to: (52, 50), inside: true, now: t0), .hold)
        // A new change while hovered keeps it up.
        XCTAssertEqual(tracker.shown(now: t0.addingTimeInterval(1), pointer: (52, 50)), .hold)
        let left = t0.addingTimeInterval(3)
        XCTAssertEqual(tracker.pointerExited(now: left), .hide(at: left.addingTimeInterval(1.2)))
    }

    func testDragHoldsAndEndsWithTheNormalDelay() {
        var tracker = OSDHoldTracker(autoHide: 1)
        _ = tracker.shown(now: t0, pointer: nil)
        XCTAssertEqual(tracker.dragBegan(), .hold)
        XCTAssertEqual(tracker.pointerExited(now: t0), .hold, "leaving mid-drag doesn't drop the HUD")
        let end = t0.addingTimeInterval(5)
        XCTAssertEqual(tracker.dragEnded(pointerInside: false, now: end), .hide(at: end.addingTimeInterval(1)))
        _ = tracker.dragBegan()
        XCTAssertEqual(tracker.dragEnded(pointerInside: true, now: end), .hold)
    }

    func testAStaleFadeIsRecognised() {
        var tracker = OSDHoldTracker(autoHide: 1)
        _ = tracker.shown(now: t0, pointer: nil)
        let fading = tracker.generation
        _ = tracker.shown(now: t0.addingTimeInterval(0.1), pointer: nil)
        XCTAssertFalse(tracker.isCurrent(fading), "a fade that ends after a newer showing must leave it up")
        XCTAssertTrue(tracker.isCurrent(tracker.generation))
    }

    func testHoverAndExitInvalidateAnAlreadyRunningFade() {
        var tracker = OSDHoldTracker(autoHide: 7)
        _ = tracker.shown(now: t0, pointer: (0, 0))
        let fading = tracker.generation
        _ = tracker.pointerMoved(to: (1, 0), inside: true, now: t0)
        XCTAssertFalse(tracker.isCurrent(fading))
        let hovered = tracker.generation
        XCTAssertEqual(tracker.pointerExited(now: t0), .hide(at: t0.addingTimeInterval(7)))
        XCTAssertFalse(tracker.isCurrent(hovered))
        tracker.hidden()
        XCTAssertFalse(tracker.isCurrent(fading))
    }

    func testVolumeSoundRequiresOptInAndCompletion() {
        for kind in [OSDContent.Kind.brightness, .volume, .mute, .input] {
            XCTAssertFalse(OSDSliderPolicy.playsSound(kind: kind, completed: false, enabled: true))
            XCTAssertFalse(OSDSliderPolicy.playsSound(kind: kind, completed: true, enabled: false))
            XCTAssertEqual(OSDSliderPolicy.playsSound(kind: kind, completed: true, enabled: true), kind == .volume)
        }
    }

    func testOnlyTheMatchingHardwareRequestCanBeVerified() {
        XCTAssertTrue(OSDAssurancePolicy.matches(requestedTarget: 40, completedTarget: 40, assurance: .requested))
        XCTAssertFalse(OSDAssurancePolicy.matches(requestedTarget: 60, completedTarget: 40, assurance: .requested))
        XCTAssertFalse(OSDAssurancePolicy.matches(requestedTarget: nil, completedTarget: 40, assurance: .requested))
        XCTAssertFalse(OSDAssurancePolicy.matches(requestedTarget: 40, completedTarget: 40, assurance: .applied))
    }

    func testUnderMenuBarLayoutAndMenuSuppression() {
        let centered = OSDLayout.origin(position: .underMenuBar, width: 200, height: 100,
                                        visibleFrame: screen, icon: nil, rightToLeft: false)
        XCTAssertEqual(centered.x, 400)
        XCTAssertEqual(centered.y, 800 - 100 - OSDLayout.menuBarGap)
        let anchored = settings { $0.osdPosition = .underMenuBar; $0.publishOSDEventsEnabled = true }
        let route = OSDFeedbackPolicy.route(.init(kind: .brightness, localHUDWanted: true, menuOpen: true),
                                            settings: anchored)
        XCTAssertFalse(route.drawsLocalHUD)
        XCTAssertTrue(route.publishesEvent)
    }

    func testHiddenResetsHover() {
        var tracker = OSDHoldTracker(autoHide: 1)
        _ = tracker.shown(now: t0, pointer: (1, 1))
        _ = tracker.pointerMoved(to: (2, 2), inside: true, now: t0)
        tracker.hidden()
        XCTAssertFalse(tracker.hovered)
        XCTAssertEqual(tracker.shown(now: t0, pointer: (2, 2)), .hide(at: t0.addingTimeInterval(1)))
    }

    // MARK: Slider

    func testSliderLevelsAndSteps() {
        XCTAssertEqual(OSDSliderPolicy.level(atX: 50, trackMinX: 0, trackWidth: 100), 0.5)
        XCTAssertEqual(OSDSliderPolicy.level(atX: -20, trackMinX: 0, trackWidth: 100), 0)
        XCTAssertEqual(OSDSliderPolicy.level(atX: 150, trackMinX: 0, trackWidth: 100), 1)
        XCTAssertNil(OSDSliderPolicy.level(atX: 10, trackMinX: 0, trackWidth: 0))
        XCTAssertNil(OSDSliderPolicy.level(atX: .nan, trackMinX: 0, trackWidth: 100))
        XCTAssertEqual(OSDSliderPolicy.stepped(0.5, by: 0.0625, up: true), 0.5625)
        XCTAssertEqual(OSDSliderPolicy.stepped(0.02, by: 0.0625, up: false), 0)
        XCTAssertEqual(OSDSliderPolicy.stepped(0.99, by: 0.0625, up: true), 1)
        XCTAssertTrue(OSDSliderPolicy.isAdjustable(.brightness))
        XCTAssertTrue(OSDSliderPolicy.isAdjustable(.volume))
        XCTAssertFalse(OSDSliderPolicy.isAdjustable(.mute))
        XCTAssertFalse(OSDSliderPolicy.isAdjustable(.input))
    }

    // MARK: Truthful values

    func testReadBackDecidesWhatTheHUDClaims() {
        let shown = OSDContent(kind: .brightness, value: 0.8, assurance: .requested)
        XCTAssertEqual(OSDAssurancePolicy.content(shown, after: .applied, maxValue: 100).assurance, .verified)
        let ignored = OSDAssurancePolicy.content(shown, after: .ignored(actual: 30), maxValue: 100)
        XCTAssertEqual(ignored.assurance, .notConfirmed)
        XCTAssertEqual(ignored.value, 0.3, accuracy: 1e-6, "the bar moves to what the panel reports")
        let silent = OSDAssurancePolicy.content(shown, after: .unknown, maxValue: 100)
        XCTAssertEqual(silent.assurance, .notConfirmed, "no answer is not a confirmation")
        XCTAssertEqual(silent.value, 0.8, accuracy: 1e-6)
        XCTAssertEqual(OSDAssurancePolicy.content(shown, after: .ignored(actual: 30), maxValue: nil).value, 0.8,
                       accuracy: 1e-6, "no scale, no invented level")
    }

    // MARK: Persistence

    func testFeedbackSettingsDefaultWhenAbsentAndDegradeAlone() throws {
        let older = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data(#"{"osdEnabled": false}"#.utf8))
        XCTAssertEqual(older.osdFeedback, .default)
        XCTAssertFalse(older.osdEnabled)
        XCTAssertFalse(older.osdFeedback.interactive, "the HUD stays click-through unless asked")
        XCTAssertFalse(older.osdFeedback.receiverHandshakeEnabled, "no other app may change feedback until allowed")

        let odd = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data(
            #"{"osdFeedback": {"screen": "elsewhere", "showsValue": false, "volumeHiddenDisplayIDs": ["d1"]}, "osdPosition": "somewhere"}"#.utf8))
        XCTAssertEqual(odd.osdFeedback.screen, .affectedDisplay)
        XCTAssertFalse(odd.osdFeedback.showsValue)
        XCTAssertEqual(odd.osdFeedback.volumeHiddenDisplayIDs, ["d1"])
        XCTAssertEqual(odd.osdPosition, .bottomCenter)
    }

    func testFeedbackSettingsRoundTrip() throws {
        var original = OpenDisplaySettings.default
        original.osdPosition = .underMenuBarIcon
        original.osdFeedback = OSDFeedbackSettings(
            showsCustomFeedback: false, volumeHiddenDisplayIDs: ["a", "b"], screen: .primary, showsValue: false,
            segmentedBar: false, interactive: true, receiverHandshakeEnabled: true,
            receiverClaim: OSDReceiverClaim(
                receiver: "Notch", prior: .init(showsBasicFeedback: true, showsCustomFeedback: true, publishing: false),
                applied: .init(showsBasicFeedback: false, showsCustomFeedback: true, publishing: true)),
            volumeCompletionSound: true, rounded: true, adaptiveBackground: false, shadow: false)
        let decoded = try JSONDecoder().decode(OpenDisplaySettings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testAnArchiveExportsUserPreferencesAndImportEndsReceiverOwnership() {
        var live = OpenDisplaySettings.default
        OSDReceiverHandshake.claim(for: "Notch", hideBasic: true, hideCustom: true, settings: &live)
        let exported = live.withoutRestoreLedgers()
        XCTAssertNil(exported.osdFeedback.receiverClaim)
        XCTAssertTrue(exported.osdEnabled)
        XCTAssertTrue(exported.osdFeedback.showsCustomFeedback)
        XCTAssertFalse(exported.publishOSDEventsEnabled)
        XCTAssertNotNil(live.osdFeedback.receiverClaim, "export never changes live settings")
        var imported = OpenDisplaySettings.default.withRestoreLedgers(from: live)
        XCTAssertNil(imported.osdFeedback.receiverClaim)
        OSDReceiverHandshake.release(&imported)
        XCTAssertEqual(imported, .default)
    }
}

/// Owner decision #8: group followers' brightness writes are published, as `groupSync`, and draw
/// nothing locally.
final class OSDGroupFollowerEventTests: XCTestCase {
    func testFollowerWritesArePublishedWhenEventsAreOnAndNeverDrawn() {
        var settings = OpenDisplaySettings.default
        XCTAssertEqual(OSDFeedbackPolicy.groupFollowerRoute(settings: settings),
                       .init(drawsLocalHUD: false, publishesEvent: false))
        settings.publishOSDEventsEnabled = true
        XCTAssertEqual(OSDFeedbackPolicy.groupFollowerRoute(settings: settings),
                       .init(drawsLocalHUD: false, publishesEvent: true))
        // Even with every local feedback switch on and an app-drawn style.
        settings.osdEnabled = true
        settings.osdStyle = .native
        XCTAssertFalse(OSDFeedbackPolicy.groupFollowerRoute(settings: settings).drawsLocalHUD)
    }

    func testTheFollowerSourceIsItsOwn() {
        XCTAssertEqual(OSDBroadcast.Source.groupSync.rawValue, "groupSync")
        let event = OSDBroadcast(kind: .brightness, value: 0.4, maxValue: 1, displayID: "follower",
                                 source: OSDBroadcast.Source.groupSync.rawValue, timestamp: 1)
        XCTAssertEqual(OSDBroadcast(userInfo: event.userInfo)?.source, "groupSync")
    }
    func testNativeFallbackFeedbackHonoursMenuSuppressionAndExternalOnly() {
        var settings = OpenDisplaySettings()
        settings.publishOSDEventsEnabled = true
        settings.osdPosition = .underMenuBarIcon
        let volume = OSDFeedbackPolicy.Context(kind: .volume, localHUDWanted: true, menuOpen: true)
        let muted = OSDFeedbackPolicy.Context(kind: .mute, localHUDWanted: true, menuOpen: true)
        for context in [volume, muted] {
            XCTAssertFalse(OSDFeedbackPolicy.route(context, settings: settings).drawsLocalHUD)
            settings.osdPosition = .center
            XCTAssertTrue(OSDFeedbackPolicy.route(context, settings: settings).drawsLocalHUD)
            settings.osdStyle = .external
            XCTAssertFalse(OSDFeedbackPolicy.route(context, settings: settings).drawsLocalHUD)
            settings.osdStyle = .native
            settings.osdPosition = .underMenuBarIcon
        }
    }

    func testBothLegacyVolumeFeedbackOptOutsUseOneEffectivePreference() {
        let id = DisplayRecordID.forCGUUID("desk")
        for keyboardHidden in [true, false] {
            for feedbackHidden in [true, false] {
                var settings = OpenDisplaySettings()
                settings.keyboardAudioByDisplay[id.rawValue] = .init(keyboardControl: false,
                    nativeAudioEnabled: true, nativeAudioDevice: "USB", showsVolumeOSD: !keyboardHidden)
                if feedbackHidden { settings.osdFeedback.volumeHiddenDisplayIDs.insert(id.rawValue) }
                XCTAssertEqual(settings.showsVolumeFeedback(for: id), !keyboardHidden && !feedbackHidden)
                for kind in [OSDContent.Kind.volume, .mute] {
                    let context = OSDFeedbackPolicy.Context(kind: kind, displayID: id.rawValue, localHUDWanted: true)
                    XCTAssertEqual(OSDFeedbackPolicy.route(context, settings: settings).drawsLocalHUD,
                                   !keyboardHidden && !feedbackHidden)
                }
                settings.setShowsVolumeFeedback(true, for: id)
                XCTAssertTrue(settings.showsVolumeFeedback(for: id))
                settings.setShowsVolumeFeedback(false, for: id)
                XCTAssertFalse(settings.showsVolumeFeedback(for: id))
                XCTAssertFalse(settings.osdFeedback.volumeHiddenDisplayIDs.contains(id.rawValue))
                XCTAssertEqual(settings.keyboardAudioByDisplay[id.rawValue]?.nativeAudioDevice, "USB")
                XCTAssertEqual(settings.keyboardAudioByDisplay[id.rawValue]?.keyboardControl, false)
            }
        }
    }

}
