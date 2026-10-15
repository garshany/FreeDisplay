import DisplayDomain
import XCTest
@testable import TopologyCore

final class ShortcutActionPolicyTests: XCTestCase {
    func testCommonStandardAndFineStepsIgnoreNativeFineDefault() {
        let steps = AdjustmentSteps(range: 100, standard: 10, fine: 2, fineByDefault: true)
        XCTAssertEqual(ShortcutActionPolicy.adjustment(for: .brightnessUp, steps: steps), .brightness(delta: 0.1))
        XCTAssertEqual(ShortcutActionPolicy.adjustment(for: .brightnessDownFine, steps: steps), .brightness(delta: -0.02))
        XCTAssertEqual(ShortcutActionPolicy.adjustment(for: .softwareContrastDown, steps: steps), .contrast(delta: -0.1))
        XCTAssertEqual(ShortcutActionPolicy.adjustment(for: .softwareContrastUpFine, steps: steps), .contrast(delta: 0.02))
        XCTAssertEqual(ShortcutActionPolicy.adjustment(for: .volumeUp, steps: steps), .volume(delta: 0.1))
        XCTAssertEqual(ShortcutActionPolicy.adjustment(for: .volumeDownFine, steps: steps), .volume(delta: -0.02))
        XCTAssertEqual(ShortcutActionPolicy.adjustment(for: .warmer, steps: steps), .temperature(delta: -0.1))
    }

    func testSoftwareStepsUseExistingSpansAndNeutralState() {
        XCTAssertEqual(ShortcutActionPolicy.contrast(nil, delta: 0.1), 1.1, accuracy: 0.00001)
        XCTAssertEqual(ShortcutActionPolicy.contrast(1.4, delta: 1), SoftwareContrast.maximum)
        XCTAssertEqual(ShortcutActionPolicy.contrast(0.6, delta: -1), SoftwareContrast.minimum)
        XCTAssertEqual(ShortcutActionPolicy.temperature(nil, delta: -0.1), 5840)
        XCTAssertEqual(ShortcutActionPolicy.temperature(2800, delta: -1), ColorTemperatureCurve.minKelvin)
        XCTAssertEqual(ShortcutActionPolicy.temperature(9000, delta: 1), ColorTemperatureCurve.maxKelvin)
    }

    func testHeldLevelsRepeatButToggleQuitRestartDoNotAndReleaseIsOnce() {
        for action in HotkeyAction.allCases {
            var gesture = ShortcutKeyGesture()
            XCTAssertEqual(gesture.event(isDown: false, repeats: ShortcutActionPolicy.repeats(action)), .ignore)
            XCTAssertEqual(gesture.event(isDown: true, repeats: ShortcutActionPolicy.repeats(action)), .invoke)
            XCTAssertEqual(gesture.event(isDown: true, repeats: ShortcutActionPolicy.repeats(action)),
                           ShortcutActionPolicy.repeats(action) ? .invoke : .ignore)
            XCTAssertEqual(gesture.event(isDown: false, repeats: ShortcutActionPolicy.repeats(action)), .release)
            XCTAssertEqual(gesture.event(isDown: false, repeats: ShortcutActionPolicy.repeats(action)), .ignore)
        }
        for action: HotkeyAction in [.quit, .restart, .toggleMenu, .toggleConsole, .toggleMute, .toggleSoftwareAdjustments] {
            XCTAssertFalse(ShortcutActionPolicy.repeats(action))
        }
    }

    func testShortcutAudioUsesConfiguredTargetsAndDeduplicatesUIDsDespiteNativeKeySwitches() {
        let output = AudioOutputDevice(uid: "usb", name: "Speakers", transport: .usb,
            volume: .settable, mute: .settable, volumeLevel: 0.5, isMuted: false)
        let candidates = ["a", "b"].map { id in
            AudioKeyCandidate(observation: .init(recordID: .init(rawValue: id), isActive: true,
                displayClass: .external, generation: .initial), productName: id, sink: .native(output))
        }
        let preferences = NativeKeyPreferences(volumeKeysEnabled: false, audioEngagement: .outputLacksVolumeControl,
            audioTarget: .allDisplays, nativeAudioFallback: false, muteKeyLeftToMacOS: true)
        XCTAssertEqual(ShortcutActionPolicy.audioDecision(.muteToggle, preferences: preferences,
            candidates: candidates, currentOutput: output, pointer: nil, focusedDisplay: nil),
            .adjust([.native(.init(rawValue: "a"), output)], feedbackOutputUID: "usb"))
        let fallbackOff = ShortcutActionPolicy.audioDecision(.volumeUp, preferences: preferences,
            candidates: [], currentOutput: output, pointer: nil, focusedDisplay: nil)
        XCTAssertEqual(fallbackOff, .passThrough(.noCapableTarget))
    }

    func testSoftwareImageTargetsDoNotCollapseBrightnessGroupMembers() {
        let group = UUID()
        let source = DisplayObservation(recordID: .init(rawValue: "source"), isActive: true,
            isMain: true, displayClass: .external, generation: .initial)
        let mirror = DisplayObservation(recordID: .init(rawValue: "mirror"), isActive: true,
            mirrorSourceID: source.recordID, displayClass: .external, generation: .initial)
        let candidates = [source, mirror].map { BrightnessKeyRouter.Candidate(observation: $0, syncGroup: group) }
        let context = BrightnessKeyRouter.Context(mode: .focusedWindow, focusedDisplay: source.recordID)
        XCTAssertEqual(ShortcutActionPolicy.videoDecision(candidates: candidates, context: context).targets.count, 1)
        XCTAssertEqual(ShortcutActionPolicy.videoDecision(candidates: candidates, context: context,
            softwareImage: true).targets.map(\.display), [source.recordID, mirror.recordID])
    }

    func testRecordedShortcutsIgnoreNativeKeyboardExclusionWithoutRedirectingToFallback() {
        let bound = AudioOutputDevice(uid: "bound", name: "Bound USB", transport: .usb,
            volume: .settable, mute: .settable, volumeLevel: 0.5, isMuted: false)
        let other = AudioOutputDevice(uid: "default", name: "Default USB", transport: .usb,
            volume: .settable, mute: .settable, volumeLevel: 0.5, isMuted: false)
        let display = DisplayObservation(recordID: .init(rawValue: "display"), isActive: true,
            mode: .init(pixelWidth: 100, pixelHeight: 100, pointWidth: 100, pointHeight: 100,
                        refreshHz: 60, isHiDPI: false), displayClass: .external, generation: .initial)
        let audio = AudioKeyCandidate(observation: display, productName: "Display", keyboardEnabled: false,
                                      sink: .native(bound))
        let prefs = NativeKeyPreferences(audioTarget: .underCursor, nativeAudioFallback: true)
        let pointer = DisplayOrigin(x: 10, y: 10)
        for action: MediaKeyAction in [.volumeUp, .muteToggle] {
            XCTAssertEqual(ShortcutActionPolicy.audioDecision(action, preferences: prefs, candidates: [audio],
                currentOutput: other, pointer: pointer, focusedDisplay: nil).recipients, [.native(display.recordID, bound)])
            XCTAssertEqual(AudioKeyRouter.decide(action, intent: .plain, candidates: [audio],
                context: .init(engagement: .always, targetMode: .underCursor, currentOutput: other, pointer: pointer))
                .recipients, [.currentOutput(other)])
        }
        let video = BrightnessKeyRouter.Candidate(observation: display, keyboardEnabled: false)
        let context = BrightnessKeyRouter.Context(mode: .underCursor, pointer: pointer)
        XCTAssertEqual(BrightnessKeyRouter.decide(intent: .plain, candidates: [video], context: context), .passThrough(.noTarget))
        XCTAssertEqual(ShortcutActionPolicy.videoDecision(candidates: [video], context: context).targets.map(\.display), [display.recordID])
    }

    func testShortcutVolumeFeedbackReplacesRepeatsAndIsConsumedOnceOrCancelled() {
        var feedback = ShortcutReleaseFeedback()
        feedback.pressHandled(.volumeUp, request: .init(outputUID: "old"))
        feedback.pressHandled(.volumeUp, request: .init(outputUID: "new"))
        feedback.pressHandled(.volumeDownFine, request: .init(outputUID: "other"))
        XCTAssertEqual(feedback.released(.volumeUp)?.outputUID, "new")
        XCTAssertNil(feedback.released(.volumeUp))
        feedback.cancel()
        XCTAssertNil(feedback.released(.volumeDownFine))
        feedback.pressHandled(.volumeDown, request: .init(outputUID: "usb"))
        feedback.pressHandled(.volumeDown, request: nil)
        XCTAssertNil(feedback.released(.volumeDown))
    }

    func testAllNewActionsPersistClearAndShareSingleRegistrationAndRecoveryReservation() throws {
        let added: [HotkeyAction] = [.toggleConsole, .restart, .softwareContrastUp, .softwareContrastDown,
            .softwareContrastUpFine, .softwareContrastDownFine, .warmer, .cooler, .resetSoftwareAdjustments,
            .toggleSoftwareAdjustments, .volumeUp, .volumeDown, .volumeUpFine, .volumeDownFine, .toggleMute, .mute, .unmute]
        for action in added {
            var registry = KeyboardShortcutRegistry()
            let chord = KeyBinding(keyCode: 0, modifiers: KeyBinding.command)
            registry.setBinding(chord, for: action)
            let decoded = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: JSONEncoder().encode(registry))
            XCTAssertEqual(decoded.effective(reconnectAllEnabled: true).binding(for: action), chord)
            registry.setBinding(chord, for: .openSettings)
            let plan = HotkeyRegistrationPlan(registry: registry.effective(reconnectAllEnabled: true))
            XCTAssertEqual(plan.registrations.filter { $0.binding == chord }.count, 1)
            XCTAssertEqual(plan.status(for: action, failed: [], paused: false), .conflict(holder: .action(.openSettings)))
            registry.setBinding(KeyboardShortcutRegistry.recoveryChord, for: action)
            let effective = registry.effective(reconnectAllEnabled: true)
            XCTAssertTrue(effective.isReservedForRecovery(KeyboardShortcutRegistry.recoveryChord, slot: .action(action)))
            XCTAssertEqual(HotkeyRegistrationPlan(registry: effective).status(for: action, failed: [], paused: false),
                           .conflict(holder: .action(.reconnectAll)))
            registry.setBinding(nil, for: action)
            XCTAssertNil(registry.mergedWithDefaults().binding(for: action))
        }
    }
}
