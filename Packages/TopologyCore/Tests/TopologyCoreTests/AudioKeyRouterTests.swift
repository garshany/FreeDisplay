import XCTest
@testable import DisplayDomain
@testable import TopologyCore

/// SO-25 / SO-27 / SO-28 / TA-06 / TB-08 / TR-16 / FA-26: volume and mute key engagement, targets,
/// explicit bindings, native fallback and feedback routing.
final class AudioKeyRouterTests: XCTestCase {
    // MARK: Fixtures

    func testPassThroughProbesOnlyUnconfirmedHardwareAndHonorsSafeStartupAndMutePolicy() {
        let output = AudioOutputDevice(uid: "usb", name: "Speakers", transport: .usb,
            volume: .settable, mute: .settable, volumeLevel: 0.5, isMuted: false)
        func candidate(_ id: String, sink: DisplayAudioSink, keyboard: Bool = true) -> AudioKeyCandidate {
            .init(observation: .init(recordID: .init(rawValue: id), cgDisplayID: 1, isActive: true,
                displayClass: .external, physicalPresence: .physical, generation: .initial),
                productName: id, keyboardEnabled: keyboard, sink: sink, matchOverride: .matched(output))
        }
        let hardware = candidate("hardware", sink: .hardware(volume: false, mute: false))
        let native = candidate("native", sink: .native(output))
        let unresolved = candidate("missing", sink: .unresolvedNative(.unset))
        let disabled = candidate("disabled", sink: .hardware(volume: false, mute: false), keyboard: false)
        let known = candidate("known", sink: .hardware(volume: true, mute: false))
        let candidates = [hardware, native, unresolved, disabled, known]
        func targets(_ action: MediaKeyAction = .volumeUp, safe: Bool = false, leaveMute: Bool = false,
                     capture: Bool = true) -> [DisplayRecordID] {
            DisplayAudioInitialRead.keyPressTargets(action: action, candidates: candidates,
                currentOutput: output, confirmedVolume: [known.id], captureEnabled: capture,
                safeStartup: safe, muteLeftToMacOS: leaveMute)
        }
        XCTAssertEqual(targets(), [hardware.id])
        XCTAssertTrue(targets(safe: true).isEmpty)
        XCTAssertTrue(targets(.muteToggle, leaveMute: true).isEmpty)
        XCTAssertTrue(targets(capture: false).isEmpty)
        XCTAssertEqual(targets(.volumeDown, leaveMute: true), [hardware.id])
    }

    private func obs(_ id: String, active: Bool = true, main: Bool = false, builtIn: Bool = false,
                     x: Int = 0, mirrors: String? = nil) -> DisplayObservation {
        DisplayObservation(
            recordID: DisplayRecordID(rawValue: id), isActive: active, origin: DisplayOrigin(x: x, y: 0),
            mode: DisplayMode(pixelWidth: 1920, pixelHeight: 1080, pointWidth: 1920, pointHeight: 1080,
                              refreshHz: 60, isHiDPI: false),
            isMain: main, mirrorSourceID: mirrors.map(DisplayRecordID.init(rawValue:)),
            displayClass: builtIn ? .builtIn : .external, generation: .initial)
    }

    private func ddc(_ id: String, name: String, x: Int = 0, volume: Bool = true, mute: Bool = true,
                     keyboard: Bool = true, override: AudioDeviceResolution = .unset,
                     mirrors: String? = nil, main: Bool = false) -> AudioKeyCandidate {
        AudioKeyCandidate(observation: obs(id, main: main, x: x, mirrors: mirrors), productName: name,
                          keyboardEnabled: keyboard, sink: .hardware(volume: volume, mute: mute),
                          matchOverride: override)
    }

    private func native(_ id: String, name: String, device: AudioOutputDevice, x: Int = 0) -> AudioKeyCandidate {
        AudioKeyCandidate(observation: obs(id, x: x), productName: name, sink: .native(device))
    }

    private let dellAudio = AudioOutputDevice(uid: "hdmi-dell", name: "DELL U2720Q", transport: .hdmi)
    private let lgAudio = AudioOutputDevice(uid: "dp-lg", name: "LG HDR 4K", transport: .displayPort)
    private let headphones = AudioOutputDevice(uid: "bt-airpods", name: "AirPods Pro", transport: .bluetooth,
                                               volume: .settable, mute: .absent, volumeLevel: 0.3)
    private let usbSpeakers = AudioOutputDevice(uid: "usb-speakers", name: "Desk Speakers", transport: .usb,
                                                volume: .settable, mute: .settable, volumeLevel: 0.5, isMuted: false)
    private let builtInSpeakers = AudioOutputDevice(uid: "builtin", name: "MacBook Pro Speakers",
                                                    transport: .builtIn, volume: .settable, mute: .settable,
                                                    volumeLevel: 0.5, isMuted: false)
    private let multiOutput = AudioOutputDevice(uid: "aggregate-1", name: "Desk Multi-Output", transport: .aggregate)

    private func decide(_ action: MediaKeyAction, _ candidates: [AudioKeyCandidate],
                        output: AudioOutputDevice?, engagement: AudioKeyEngagement = .outputMatchesDisplay,
                        target: AudioKeyTargetMode = .matchingOutput, fallback: Bool = true,
                        muteToMacOS: Bool = false, intent: NativeKeyIntent = .plain,
                        pointer: DisplayOrigin? = nil, focused: String? = nil) -> AudioKeyRouter.Decision {
        AudioKeyRouter.decide(action, intent: intent, candidates: candidates,
                              context: .init(engagement: engagement, targetMode: target, nativeFallback: fallback,
                                             muteLeftToMacOS: muteToMacOS, currentOutput: output,
                                             pointer: pointer, focusedDisplay: focused.map(DisplayRecordID.init)))
    }

    private func rid(_ id: String) -> DisplayRecordID { DisplayRecordID(rawValue: id) }

    // MARK: - Default engagement: the current output belongs to a controllable display

    func testHDMIOutputOfAMonitorWithConfirmedVolumeIsTaken() {
        let decision = decide(.volumeUp, [ddc("dell", name: "DELL U2720Q")], output: dellAudio)
        XCTAssertEqual(decision, .adjust([.hardware(rid("dell"))], feedbackOutputUID: "hdmi-dell"))
    }

    func testHeadphonesLeaveTheKeysToMacOSAndNeverTouchTheMonitor() {
        let decision = decide(.volumeUp, [ddc("dell", name: "DELL U2720Q")], output: headphones)
        XCTAssertEqual(decision, .passThrough(.notEngaged))
    }

    func testUnconfirmedMonitorVolumeLeavesTheKeysToMacOS() {
        // TB-02 stays: no read-back level, no engagement — even with the fallback on, an HDMI output
        // without its own CoreAudio volume gives the key back to macOS.
        let decision = decide(.volumeUp, [ddc("dell", name: "DELL U2720Q", volume: false, mute: false)], output: dellAudio)
        XCTAssertEqual(decision, .passThrough(.notEngaged))
    }

    func testIdenticalMonitorsAreAmbiguousWithoutABinding() {
        let decision = decide(.volumeUp, [ddc("a", name: "DELL U2720Q"), ddc("b", name: "DELL U2720Q", x: 1920)],
                              output: dellAudio)
        XCTAssertEqual(decision, .passThrough(.notEngaged))
    }

    func testAUIDOverrideResolvesIdenticalMonitors() {
        let decision = decide(.volumeDown, [ddc("a", name: "DELL U2720Q"),
                                            ddc("b", name: "DELL U2720Q", x: 1920, override: .matched(dellAudio))],
                              output: dellAudio)
        XCTAssertEqual(decision.recipients, [.hardware(rid("b"))])
    }

    func testAnAmbiguousOrMissingOverrideRedirectsNothing() {
        for override in [AudioDeviceResolution.ambiguous([dellAudio, lgAudio]), .missing] {
            let decision = decide(.volumeUp, [ddc("a", name: "DELL U2720Q", override: override)], output: dellAudio)
            XCTAssertEqual(decision, .passThrough(.notEngaged), "\(override)")
        }
    }

    func testAnExplicitOverrideMayNameSeveralDisplaysOnPurpose() {
        // A multi-output device feeding two monitors: both bound to it, both change.
        let decision = decide(.volumeUp, [ddc("a", name: "A", override: .matched(multiOutput)),
                                          ddc("b", name: "B", x: 1920, override: .matched(multiOutput))],
                              output: multiOutput)
        XCTAssertEqual(decision, .adjust([.hardware(rid("a")), .hardware(rid("b"))], feedbackOutputUID: nil))
    }

    func testAnUnmatchedOutputNeverInfersTheOnlyExternal() {
        // Neither a sole external nor a second display is evidence of an output association.
        let single = decide(.volumeUp, [ddc("a", name: "Monitor A")], output: dellAudio)
        XCTAssertEqual(single, .passThrough(.notEngaged))
        let two = decide(.volumeUp, [ddc("a", name: "Monitor A"),
                                     ddc("b", name: "Monitor B", x: 1920, override: .matched(usbSpeakers))],
                         output: dellAudio)
        XCTAssertEqual(two, .passThrough(.notEngaged))
    }

    func testKeyboardExcludedDisplaysAreNotTargets() {
        let decision = decide(.volumeUp, [ddc("dell", name: "DELL U2720Q", keyboard: false)], output: dellAudio)
        XCTAssertEqual(decision, .passThrough(.notEngaged))
    }

    // MARK: - Native association (public CoreAudio)

    func testAUSBOutputBoundToADisplayIsAdjustedWithoutMovingPlayback() {
        let candidates = [native("desk", name: "LG HDR 4K", device: usbSpeakers)]
        // The keys follow the binding when that output plays…
        XCTAssertEqual(decide(.volumeUp, candidates, output: usbSpeakers),
                       .adjust([.native(rid("desk"), usbSpeakers)], feedbackOutputUID: "usb-speakers"))
        // …and with "any controllable display" engagement the bound output changes even while macOS
        // plays elsewhere; nothing here selects a different system output.
        XCTAssertEqual(decide(.volumeUp, candidates, output: headphones, engagement: .anyControllableDisplay,
                              target: .allDisplays).recipients,
                       [.native(rid("desk"), usbSpeakers)])
    }

    func testABoundOutputReplacesTheMonitorsOwnAudio() {
        // The display's product name matches the HDMI output, but it is bound to the USB speakers.
        let candidates = [native("dell", name: "DELL U2720Q", device: usbSpeakers)]
        XCTAssertEqual(decide(.volumeUp, candidates, output: dellAudio, fallback: false), .passThrough(.notEngaged))
    }

    func testAnUnresolvedBindingGivesTheDisplayNoAudioControl() {
        let candidate = AudioKeyCandidate(observation: obs("dell"), productName: "DELL U2720Q",
                                          sink: .unresolvedNative(.missing))
        XCTAssertFalse(candidate.isControllable)
        XCTAssertEqual(decide(.volumeUp, [candidate], output: dellAudio, engagement: .always, fallback: false),
                       .passThrough(.noCapableTarget))
    }

    func testVolumeOnlyOutputsAreNotMuteCapable() {
        let candidates = [native("desk", name: "Desk", device: headphones)]
        XCTAssertEqual(decide(.volumeUp, candidates, output: headphones).recipients, [.native(rid("desk"), headphones)])
        XCTAssertEqual(decide(.muteToggle, candidates, output: headphones), .passThrough(.noCapableTarget))
    }

    func testTwoDisplaysBoundToOneOutputWriteItOnce() {
        let decision = decide(.volumeUp, [native("a", name: "A", device: usbSpeakers),
                                          native("b", name: "B", device: usbSpeakers, x: 1920)],
                              output: usbSpeakers)
        XCTAssertEqual(decision.recipients, [.native(rid("a"), usbSpeakers)])
    }

    // MARK: - Engagement alternatives

    func testOutputLacksVolumeControlEngagesOnlyForSuchOutputs() {
        let candidates = [ddc("dell", name: "DELL U2720Q")]
        XCTAssertEqual(decide(.volumeUp, candidates, output: dellAudio, engagement: .outputLacksVolumeControl).recipients,
                       [.hardware(rid("dell"))])
        XCTAssertEqual(decide(.volumeUp, candidates, output: builtInSpeakers, engagement: .outputLacksVolumeControl),
                       .passThrough(.notEngaged), "the built-in speakers have their own volume")
    }

    func testAlwaysWithNoDisplayTargetUsesTheNativeFallback() {
        let decision = decide(.volumeUp, [ddc("dell", name: "DELL U2720Q")], output: headphones, engagement: .always)
        XCTAssertEqual(decision, .adjust([.currentOutput(headphones)], feedbackOutputUID: "bt-airpods"))
        XCTAssertEqual(decide(.volumeUp, [ddc("dell", name: "DELL U2720Q")], output: headphones, engagement: .always,
                              fallback: false), .passThrough(.noCapableTarget))
    }

    func testFallbackNeedsTheActionOnTheOutputItself() {
        // Engaged by a matching monitor whose mute isn't confirmed: the HDMI output has no CoreAudio
        // mute either, so the key goes to macOS instead of being swallowed.
        let decision = decide(.muteToggle, [ddc("dell", name: "DELL U2720Q", mute: false)], output: dellAudio)
        XCTAssertEqual(decision, .passThrough(.noCapableTarget))
        var mutableHDMI = dellAudio
        mutableHDMI.mute = .settable
        mutableHDMI.isMuted = false
        XCTAssertEqual(decide(.muteToggle, [ddc("dell", name: "DELL U2720Q", mute: false)], output: mutableHDMI),
                       .adjust([.currentOutput(mutableHDMI)], feedbackOutputUID: "hdmi-dell"))
    }

    func testUnavailableOutputPassesThrough() {
        XCTAssertEqual(decide(.volumeUp, [ddc("dell", name: "DELL U2720Q")], output: nil), .passThrough(.notEngaged))
        XCTAssertEqual(decide(.volumeUp, [], output: nil, engagement: .always), .passThrough(.noCapableTarget))
    }

    // MARK: - Mute pass-through

    func testMuteLeftToMacOSKeepsVolumeKeys() {
        let candidates = [ddc("dell", name: "DELL U2720Q")]
        XCTAssertEqual(decide(.muteToggle, candidates, output: dellAudio, muteToMacOS: true),
                       .passThrough(.muteLeftToMacOS))
        XCTAssertEqual(decide(.volumeDown, candidates, output: dellAudio, muteToMacOS: true).recipients,
                       [.hardware(rid("dell"))])
    }

    // MARK: - Target modes

    func testPointerTargetIgnoresTheOutputMatch() {
        let candidates = [ddc("dell", name: "DELL U2720Q", main: true), ddc("lg", name: "LG HDR 4K", x: 1920)]
        let decision = decide(.volumeUp, candidates, output: dellAudio, target: .underCursor,
                              pointer: DisplayOrigin(x: 2000, y: 10))
        XCTAssertEqual(decision, .adjust([.hardware(rid("lg"))], feedbackOutputUID: nil),
                       "the sound plays on the default output: the LG isn't the current output")
    }

    func testFocusTargetIncludesTheMirrorSet() {
        let candidates = [ddc("dell", name: "DELL U2720Q", main: true),
                          ddc("dell-mirror", name: "LG HDR 4K", mirrors: "dell")]
        let decision = decide(.volumeUp, candidates, output: dellAudio, target: .focusedWindow, focused: "dell")
        XCTAssertEqual(decision.recipients, [.hardware(rid("dell")), .hardware(rid("dell-mirror"))])
    }

    func testAllTargetNarrowsToThePointerWithShift() {
        let candidates = [ddc("dell", name: "DELL U2720Q", main: true), ddc("lg", name: "LG HDR 4K", x: 1920)]
        XCTAssertEqual(decide(.volumeUp, candidates, output: dellAudio, target: .allDisplays).recipients.count, 2)
        XCTAssertEqual(decide(.volumeUp, candidates, output: dellAudio, target: .allDisplays,
                              intent: NativeKeyIntent(bypassesSync: true), pointer: DisplayOrigin(x: 2000, y: 10))
                        .recipients, [.hardware(rid("lg"))])
    }

    func testPointerAndFocusHaveNoUnrelatedFallback() {
        let candidates = [ddc("dell", name: "DELL U2720Q")]
        XCTAssertEqual(decide(.volumeUp, candidates, output: dellAudio, target: .underCursor,
                              fallback: false, pointer: .init(x: 9000, y: 0)), .passThrough(.noCapableTarget))
        XCTAssertEqual(decide(.volumeUp, candidates, output: dellAudio, target: .focusedWindow,
                              fallback: false), .passThrough(.noCapableTarget))
    }

    func testMuteOnlyOutputDoesNotAcquireVolumeCapability() {
        var device = usbSpeakers
        device.volume = .absent
        device.volumeLevel = nil
        let candidates = [native("desk", name: "Desk", device: device)]
        XCTAssertEqual(decide(.volumeUp, candidates, output: device), .passThrough(.noCapableTarget))
        XCTAssertEqual(decide(.muteToggle, candidates, output: device).recipients, [.native(rid("desk"), device)])
    }

    func testAResolvedFeedbackOutputThatDisappearsPlaysNowhere() {
        let explicit = KeyReleaseFeedback.Request(outputUID: "usb-speakers")
        XCTAssertFalse(explicit.canPlay(availableUIDs: ["headphones"]))
        XCTAssertTrue(explicit.canPlay(availableUIDs: ["usb-speakers"]))
        XCTAssertTrue(KeyReleaseFeedback.Request(outputUID: nil).canPlay(availableUIDs: ["headphones"]))
        var feedback = KeyReleaseFeedback()
        feedback.pressHandled(.volumeUp, request: explicit)
        feedback.cancel()
        XCTAssertNil(feedback.released(.volumeUp))
    }


    func testExplicitAudioStreamRelationshipDeduplicatesSharedNativeEndpoint() {
        let source = native("source", name: "A", device: usbSpeakers)
        let target = native("target", name: "B", device: usbSpeakers, x: 1920)
        let decision = AudioKeyRouter.decide(
            .volumeUp, intent: .plain, candidates: [source, target],
            context: .init(targetMode: .focusedWindow, currentOutput: usbSpeakers, focusedDisplay: source.id,
                           streamTargets: [.init(source: source.id, target: target.id)]))
        XCTAssertEqual(decision.recipients, [.native(source.id, usbSpeakers)])
    }


    func testKeyMatchingOverrideIsIndependentOfTheNativeVolumeDestination() {
        var bound = native("desk", name: "Desk", device: usbSpeakers)
        bound.matchOverride = .matched(multiOutput)
        XCTAssertEqual(decide(.volumeUp, [bound], output: multiOutput).recipients, [.native(bound.id, usbSpeakers)])
        XCTAssertEqual(decide(.volumeUp, [bound], output: usbSpeakers), .passThrough(.notEngaged))
        bound.matchOverride = .missing
        XCTAssertEqual(decide(.volumeUp, [bound], output: usbSpeakers), .passThrough(.notEngaged))
    }


    func testMissingExplicitPointerBindingCannotRedirectToNativeFallback() {
        let unresolved = AudioKeyCandidate(observation: obs("desk"), productName: "Desk",
                                            sink: .unresolvedNative(.missing))
        XCTAssertEqual(decide(.volumeUp, [unresolved], output: headphones, engagement: .always,
                              target: .underCursor, pointer: .init(x: 10, y: 10)), .passThrough(.noCapableTarget))
    }

    // MARK: - Status and feedback

    func testLaunchAndConnectInitialReadPlansEstablishFirstKeyEligibility() {
        var monitor = ddc("dell", name: "DELL U2720Q", volume: false, mute: false)
        XCTAssertEqual(DisplayAudioInitialRead.targets(candidates: [monitor], confirmedVolume: [],
                                                       captureEnabled: true, safeStartup: false), [rid("dell")])
        // The existing probe supplies its result before the first eligible key decision.
        monitor.sink = .hardware(volume: true, mute: false)
        XCTAssertEqual(decide(.volumeUp, [monitor], output: dellAudio).recipients, [.hardware(rid("dell"))])
        XCTAssertTrue(DisplayAudioInitialRead.targets(candidates: [monitor], confirmedVolume: [rid("dell")],
                                                       captureEnabled: true, safeStartup: false).isEmpty)
        let arrival = ddc("lg", name: "LG HDR 4K", volume: false, mute: false)
        XCTAssertEqual(DisplayAudioInitialRead.targets(candidates: [monitor, arrival], confirmedVolume: [rid("dell")],
                                                       captureEnabled: true, safeStartup: false), [rid("lg")])
    }

    func testStartupAudioWaitsForIdentityAndHonorsSavedNativeBindingBeforeAnyProbe() async {
        let id = DisplayRecordID.forCGUUID("UUID-A")
        let observation = DisplayObservation(recordID: id, cgDisplayID: 1, cgUUID: "UUID-A",
            isActive: true, displayClass: .external, physicalPresence: .physical, generation: .initial)
        var settings = OpenDisplaySettings.default
        var preferences = DisplayKeyboardAudioPreferences()
        preferences.nativeAudioEnabled = true
        preferences.nativeAudioDevice = usbSpeakers.uid
        settings.keyboardAudioByDisplay[id.rawValue] = preferences
        func candidate(_ record: DisplayRecord?, saved: DisplayKeyboardAudioPreferences) -> AudioKeyCandidate {
            .init(observation: observation, productName: "Desk",
                sink: .resolve(observation: observation, record: record, preferences: saved,
                               devices: [usbSpeakers], hardwareVolume: false, hardwareMute: false))
        }
        func probes(_ candidate: AudioKeyCandidate) -> [DisplayRecordID] {
            DisplayAudioInitialRead.targets(candidates: [candidate], confirmedVolume: [],
                captureEnabled: true, safeStartup: false)
        }
        // The guarded preference reader returns defaults before resolution; these cannot grant DDC.
        let unresolved = candidate(nil, saved: .init())
        XCTAssertEqual(unresolved.sink, .none)
        XCTAssertTrue(probes(unresolved).isEmpty)
        let registry = await DisplayRegistry(store: InMemoryRegistryStore())
        let record = await registry.resolve(fingerprint: .init(), cgUUID: "UUID-A")
        let native = candidate(record, saved: settings.keyboardAudioPreferences(for: id))
        XCTAssertEqual(native.sink, .native(usbSpeakers))
        XCTAssertTrue(probes(native).isEmpty)
        let hardware = candidate(record, saved: .init())
        XCTAssertEqual(probes(hardware), [id], "verified hardware still gets owner #6 discovery")
        let provisional = DisplayRecord(id: .init(rawValue: "unresolved:UUID-A"), fingerprint: .init(),
            displayClass: .external, lastSeen: Date(), unresolvedCandidates: [])
        XCTAssertTrue(probes(candidate(provisional, saved: .init())).isEmpty)
        XCTAssertTrue(probes(candidate(record, saved: .init(nativeAudioEnabled: true,
            nativeAudioDevice: "missing"))).isEmpty)
    }

    func testInitialReadsNeverProbeNativeBindingsExcludedTargetsOrSafeStartup() {
        let hardware = ddc("dell", name: "DELL U2720Q", volume: false, mute: false)
        let bound = native("desk", name: "Desk", device: usbSpeakers)
        let excluded = ddc("excluded", name: "A", keyboard: false)
        XCTAssertEqual(DisplayAudioInitialRead.targets(candidates: [hardware, bound, excluded], confirmedVolume: [],
                                                       captureEnabled: true, safeStartup: false), [rid("dell")])
        XCTAssertTrue(DisplayAudioInitialRead.targets(candidates: [hardware], confirmedVolume: [],
                                                       captureEnabled: true, safeStartup: true).isEmpty)
        XCTAssertTrue(DisplayAudioInitialRead.targets(candidates: [hardware], confirmedVolume: [],
                                                       captureEnabled: false, safeStartup: false).isEmpty)
    }

    func testStatusSeparatesVolumeOnlyFromVolumeAndMute() {
        let volumeOnly = [ddc("dell", name: "DELL U2720Q", mute: false)]
        XCTAssertEqual(AudioKeyStatus.evaluate(
            captureEnabled: true,
            volume: decide(.volumeUp, volumeOnly, output: dellAudio),
            mute: decide(.muteToggle, volumeOnly, output: dellAudio)), .volumeOnly)
        let both = [ddc("dell", name: "DELL U2720Q")]
        XCTAssertEqual(AudioKeyStatus.evaluate(
            captureEnabled: true,
            volume: decide(.volumeUp, both, output: dellAudio),
            mute: decide(.muteToggle, both, output: dellAudio, muteToMacOS: true)), .volumeOnly,
                       "leaving mute to macOS shows as volume only")
        XCTAssertEqual(AudioKeyStatus.evaluate(
            captureEnabled: true,
            volume: decide(.volumeUp, both, output: headphones),
            mute: decide(.muteToggle, both, output: headphones)), .disengaged)
        XCTAssertEqual(AudioKeyStatus.evaluate(captureEnabled: false, volume: .passThrough(.notEngaged),
                                               mute: .passThrough(.notEngaged)), .off)
    }

    func testFeedbackFollowsThePreferenceAndShiftInvertsIt() {
        XCTAssertTrue(VolumeFeedbackPolicy.plays(.followSystem, systemPreference: true, inverted: false))
        XCTAssertFalse(VolumeFeedbackPolicy.plays(.followSystem, systemPreference: nil, inverted: false),
                       "an unreadable system preference counts as off")
        XCTAssertTrue(VolumeFeedbackPolicy.plays(.followSystem, systemPreference: false, inverted: true))
        XCTAssertFalse(VolumeFeedbackPolicy.plays(.always, systemPreference: nil, inverted: true))
        XCTAssertFalse(VolumeFeedbackPolicy.plays(.never, systemPreference: true, inverted: false))
    }

    func testAHeldKeyPlaysOneSoundOnRelease() {
        var feedback = KeyReleaseFeedback()
        let request = KeyReleaseFeedback.Request(outputUID: "usb-speakers")
        for _ in 0..<5 { feedback.pressHandled(.volumeUp, request: request) }  // the press and its repeats
        XCTAssertEqual(feedback.released(.volumeUp), request)
        XCTAssertNil(feedback.released(.volumeUp), "one sound per press")
        XCTAssertNil(feedback.released(.volumeDown), "a key OpenDisplay didn't handle owes nothing")
        feedback.pressHandled(.volumeDown, request: nil)
        XCTAssertNil(feedback.released(.volumeDown))
    }

    func testListeningStateKeepsPermissionTapAndCaptureApart() {
        let both = NativeKeyPreferences()
        XCTAssertEqual(NativeKeyListening.state(featureEnabled: false, preferences: both, permissionGranted: true,
                                                tapActive: true), .off)
        var neither = both
        neither.brightnessKeysEnabled = false
        neither.volumeKeysEnabled = false
        XCTAssertEqual(NativeKeyListening.state(featureEnabled: true, preferences: neither, permissionGranted: false,
                                                tapActive: false), .off, "no capture: no permission needed")
        XCTAssertEqual(NativeKeyListening.state(featureEnabled: true, preferences: both, permissionGranted: false,
                                                tapActive: true), .permissionMissing)
        XCTAssertEqual(NativeKeyListening.state(featureEnabled: true, preferences: both, permissionGranted: true,
                                                tapActive: false), .waitingForCapture)
        XCTAssertEqual(NativeKeyListening.state(featureEnabled: true, preferences: both, permissionGranted: true,
                                                tapActive: true), .listening)
    }
}
