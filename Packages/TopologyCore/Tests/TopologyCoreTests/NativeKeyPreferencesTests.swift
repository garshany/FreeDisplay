import XCTest
import DisplayDomain
@testable import TopologyCore

/// SO-25 / SO-26 / FA-19: the modifier matrix, F14/F15, and persistence of the native-key and
/// per-display keyboard/audio preferences.
final class NativeKeyPreferencesTests: XCTestCase {
    private typealias Chord = NativeKeyChordPolicy

    // MARK: - Modifier matrix

    func testPlainShiftAndShiftOption() {
        for action in MediaKeyAction.allCases {
            XCTAssertEqual(Chord.intent(for: action, modifiers: [], brightnessRequiresShift: false), .plain)
            XCTAssertEqual(Chord.intent(for: action, modifiers: [.shift], brightnessRequiresShift: false),
                           NativeKeyIntent(bypassesSync: true, invertsFeedbackSound: true))
            XCTAssertEqual(Chord.intent(for: action, modifiers: [.shift, .option], brightnessRequiresShift: false),
                           NativeKeyIntent(modifierRequestsFine: true))
        }
    }

    func testScopeChordsAreBrightnessOnly() {
        XCTAssertEqual(Chord.intent(for: .brightnessUp, modifiers: [.control], brightnessRequiresShift: false)?.scope,
                       .builtIn)
        XCTAssertEqual(Chord.intent(for: .brightnessDown, modifiers: [.control, .command],
                                    brightnessRequiresShift: false)?.scope, .externals)
        let other = Chord.intent(for: .brightnessUp, modifiers: [.shift, .command], brightnessRequiresShift: false)
        XCTAssertEqual(other?.scope, .otherScreens)
        XCTAssertEqual(other?.bypassesSync, true)
        for chord: NativeKeyModifiers in [[.control], [.control, .command], [.shift, .command]] {
            XCTAssertNil(Chord.intent(for: .volumeUp, modifiers: chord, brightnessRequiresShift: false))
        }
    }

    func testUnsupportedChordsGoToMacOS() {
        // ⌥ alone opens Displays/Sound settings and ⌘ toggles mirroring — macOS's own meanings.
        let unsupported: [NativeKeyModifiers] = [[.option], [.command], [.option, .command], [.control, .option],
                                                 [.shift, .control], [.shift, .option, .command],
                                                 [.shift, .control, .option, .command]]
        for chord in unsupported {
            for action in MediaKeyAction.allCases {
                XCTAssertNil(Chord.intent(for: action, modifiers: chord, brightnessRequiresShift: false),
                             "\(action) \(chord.rawValue)")
            }
        }
    }

    func testRequireShiftMakesShiftTheActivationNotABypass() {
        XCTAssertNil(Chord.intent(for: .brightnessUp, modifiers: [], brightnessRequiresShift: true))
        XCTAssertEqual(Chord.intent(for: .brightnessUp, modifiers: [.shift], brightnessRequiresShift: true), .plain)
        XCTAssertEqual(Chord.intent(for: .brightnessDown, modifiers: [.shift, .option], brightnessRequiresShift: true),
                       NativeKeyIntent(modifierRequestsFine: true))
        XCTAssertNil(Chord.intent(for: .brightnessUp, modifiers: [.control], brightnessRequiresShift: true))
        // Volume keys never needed Shift.
        XCTAssertEqual(Chord.intent(for: .volumeUp, modifiers: [], brightnessRequiresShift: true), .plain)
    }

    func testFineDefaultInvertsTheModifierStep() {
        let steps = AdjustmentSteps(fineByDefault: true)
        let plain = Chord.intent(for: .brightnessUp, modifiers: [], brightnessRequiresShift: false)!
        let fine = Chord.intent(for: .brightnessUp, modifiers: [.shift, .option], brightnessRequiresShift: false)!
        XCTAssertEqual(steps.nativeKeyFraction(modifierRequestsFine: plain.modifierRequestsFine), 1.0 / 64.0)
        XCTAssertEqual(steps.nativeKeyFraction(modifierRequestsFine: fine.modifierRequestsFine), 4.0 / 64.0)
    }


    func testEveryModifierCombinationIsExplicitForEveryKey() {
        for action in MediaKeyAction.allCases {
            for raw in UInt8(0)...15 {
                let modifiers = NativeKeyModifiers(rawValue: raw)
                let intent = Chord.intent(for: action, modifiers: modifiers, brightnessRequiresShift: false)
                let auxiliary = Chord.auxiliaryAction(for: action, modifiers: modifiers, brightnessRequiresShift: false)
                let adjustment = [UInt8(0), 1, 5].contains(raw) || (action.isBrightness && [2, 10, 9].contains(raw))
                XCTAssertEqual(intent != nil, adjustment, "\(action) flags=\(raw)")
                XCTAssertEqual(auxiliary != nil, raw == 4 || (raw == 8 && action.isBrightness))
                XCTAssertFalse(intent != nil && auxiliary != nil)
            }
        }
        XCTAssertEqual(Chord.auxiliaryAction(for: .brightnessDown, modifiers: .command,
                                            brightnessRequiresShift: false), .stopMirroring)
        XCTAssertEqual(Chord.auxiliaryAction(for: .brightnessUp, modifiers: .command,
                                            brightnessRequiresShift: false), .startMirroring)
        XCTAssertNil(Chord.auxiliaryAction(for: .brightnessUp, modifiers: .option, brightnessRequiresShift: true))
    }


    func testMirrorCommandTargetsAreStableAndNeverGuessWithoutAMainDisplay() {
        let main = DisplayObservation(recordID: .init(rawValue: "main"), cgDisplayID: 1, isActive: true,
                                      isMain: true, displayClass: .builtIn, generation: .initial)
        let external = DisplayObservation(recordID: .init(rawValue: "external"), cgDisplayID: 2, isActive: true,
                                          displayClass: .external, generation: .initial)
        var mirror = external
        mirror.mirrorSourceID = main.recordID
        XCTAssertEqual(Chord.mirrorTargets(for: .startMirroring, in: [main, external]), [external.recordID])
        XCTAssertEqual(Chord.mirrorTargets(for: .stopMirroring, in: [main, mirror]), [external.recordID])
        XCTAssertTrue(Chord.mirrorTargets(for: .startMirroring, in: [external]).isEmpty)
    }


    func testBrightnessAndVolumeFineDefaultsAreIndependentAndMigrateFromSharedPreference() throws {
        let shared = AdjustmentSteps(fineByDefault: true)
        let migrated = try JSONDecoder().decode(NativeKeyPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(migrated.stepFraction(for: .volumeUp, modifierRequestsFine: false, steps: shared),
                       shared.fraction(fine: true))
        let split = NativeKeyPreferences(brightnessFineByDefault: false, volumeFineByDefault: true)
        for action in MediaKeyAction.allCases {
            XCTAssertEqual(split.stepFraction(for: action, modifierRequestsFine: false, steps: shared),
                           shared.fraction(fine: !action.isBrightness))
            XCTAssertEqual(split.stepFraction(for: action, modifierRequestsFine: true, steps: shared),
                           shared.fraction(fine: action.isBrightness))
        }
        XCTAssertEqual(try JSONDecoder().decode(NativeKeyPreferences.self, from: JSONEncoder().encode(split)), split)
    }

    // MARK: - F14/F15

    func testF14AndF15AreBrightnessKeysUnlessAShortcutUsesTheChord() {
        XCTAssertEqual(AlternativeBrightnessKey.action(forKeyCode: AlternativeBrightnessKey.f14), .brightnessDown)
        XCTAssertEqual(AlternativeBrightnessKey.action(forKeyCode: AlternativeBrightnessKey.f15), .brightnessUp)
        XCTAssertNil(AlternativeBrightnessKey.action(forKeyCode: 0x6A))  // F16
        XCTAssertTrue(AlternativeBrightnessKey.isMapped(keyCode: AlternativeBrightnessKey.f14, carbonModifiers: 0,
                                                        enabled: true, shortcutInUse: { _ in false }))
        XCTAssertFalse(AlternativeBrightnessKey.isMapped(keyCode: AlternativeBrightnessKey.f14, carbonModifiers: 0,
                                                         enabled: false, shortcutInUse: { _ in false }))
        let recorded = KeyBinding(keyCode: UInt32(AlternativeBrightnessKey.f15), modifiers: 0)
        XCTAssertFalse(AlternativeBrightnessKey.isMapped(keyCode: AlternativeBrightnessKey.f15, carbonModifiers: 0,
                                                         enabled: true, shortcutInUse: { $0 == recorded }),
                       "a recorded F15 shortcut keeps working")
        XCTAssertTrue(AlternativeBrightnessKey.isMapped(keyCode: AlternativeBrightnessKey.f15,
                                                        carbonModifiers: KeyBinding.shift,
                                                        enabled: true, shortcutInUse: { $0 == recorded }),
                      "only that exact chord is the shortcut's")
    }

    // MARK: - Persistence

    func testNativeKeyDefaults() {
        let keys = OpenDisplaySettings.default.nativeKeys
        XCTAssertTrue(keys.brightnessKeysEnabled)
        XCTAssertTrue(keys.volumeKeysEnabled)
        XCTAssertEqual(keys.brightnessTakeover, .anyControllableDisplay)
        XCTAssertTrue(keys.alternativeBrightnessKeys)
        XCTAssertEqual(keys.audioEngagement, .outputMatchesDisplay)
        XCTAssertEqual(keys.audioTarget, .matchingOutput)
        XCTAssertTrue(keys.nativeAudioFallback)
        XCTAssertFalse(keys.muteKeyLeftToMacOS)
        XCTAssertEqual(keys.volumeFeedbackSound, .followSystem)
        XCTAssertFalse(OpenDisplaySettings.default.mediaKeyInterceptionEnabled, "the feature itself stays opt-in")
        XCTAssertTrue(OpenDisplaySettings.default.keyboardAudioByDisplay.isEmpty)
    }

    func testPreferencesRoundTripAndAnOlderFileLoadsDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("od-native-keys-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        var settings = OpenDisplaySettings(mediaKeyInterceptionEnabled: true, mediaKeyTargetMode: .focusedWindow)
        settings.nativeKeys = NativeKeyPreferences(brightnessKeysEnabled: false, volumeKeysEnabled: true,
                                                   brightnessTakeover: .onlyWhenMacOSCannot,
                                                   alternativeBrightnessKeys: false, audioEngagement: .always,
                                                   audioTarget: .allDisplays, nativeAudioFallback: false,
                                                   muteKeyLeftToMacOS: true, volumeFeedbackSound: .never)
        settings.setKeyboardAudioPreferences(.init(keyboardControl: false, audioMatch: "AppleGFXHDMI:2",
                                                   nativeAudioEnabled: true, nativeAudioDevice: "usb-speakers",
                                                   showsVolumeOSD: false),
                                             for: DisplayRecordID(rawValue: "cg:DESK"))
        try store.save(settings)
        XCTAssertEqual(store.load(), settings)

        try Data(#"{"mediaKeyInterceptionEnabled":true,"mediaKeyTargetMode":"externalOnly"}"#.utf8)
            .write(to: directory.appendingPathComponent("settings.json"))
        let older = store.load()
        XCTAssertTrue(older.mediaKeyInterceptionEnabled)
        XCTAssertEqual(older.mediaKeyTargetMode, .externalOnly)
        XCTAssertEqual(older.nativeKeys, .default, "both captures on: the keys behave as before")
        XCTAssertTrue(older.keyboardAudioByDisplay.isEmpty)
    }

    func testOneDamagedDisplayEntryLosesOnlyThatEntry() throws {
        let json = #"""
        {"nativeKeys":{"audioTarget":"somethingNew","muteKeyLeftToMacOS":true},
         "keyboardAudioByDisplay":{"cg:A":{"keyboardControl":false},"cg:B":42}}
        """#
        let settings = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.nativeKeys.audioTarget, .matchingOutput, "an unknown mode degrades alone")
        XCTAssertTrue(settings.nativeKeys.muteKeyLeftToMacOS)
        XCTAssertEqual(Array(settings.keyboardAudioByDisplay.keys), ["cg:A"])
        XCTAssertFalse(settings.keyboardAudioPreferences(for: DisplayRecordID(rawValue: "cg:A")).keyboardControl)
        XCTAssertTrue(settings.keyboardAudioPreferences(for: DisplayRecordID(rawValue: "cg:B")).keyboardControl)
    }

    func testDefaultOrBlankPreferencesAreNotStored() {
        var settings = OpenDisplaySettings()
        let id = DisplayRecordID(rawValue: "cg:A")
        settings.setKeyboardAudioPreferences(.init(audioMatch: "  ", nativeAudioDevice: ""), for: id)
        XCTAssertTrue(settings.keyboardAudioByDisplay.isEmpty)
        settings.setKeyboardAudioPreferences(.init(keyboardControl: false), for: id)
        XCTAssertEqual(settings.keyboardAudioByDisplay.count, 1)
        settings.setKeyboardAudioPreferences(.default, for: id)
        XCTAssertTrue(settings.keyboardAudioByDisplay.isEmpty)
    }

    func testForgettingADisplayRemovesItsKeyboardAndAudioPreferences() throws {
        let desk = DisplayRecordID.forCGUUID("DESK")
        let laptop = DisplayRecordID.forCGUUID("LAPTOP")
        var settings = OpenDisplaySettings()
        settings.setKeyboardAudioPreferences(.init(keyboardControl: false), for: desk)
        settings.setKeyboardAudioPreferences(.init(audioMatch: "Speakers"), for: laptop)
        let entry = RememberedDisplay(id: "disp_desk", record: nil, isRegistered: false, observationIDs: [desk],
                                      status: .notConnected, offline: nil)
        let plan = try RememberedDisplayCleanup.plan(for: entry, mode: .forget, settings: settings,
                                                     favorites: FavoriteResolutions(), menuLayout: MenuLayoutSettings(),
                                                     ledger: [])
        XCTAssertTrue(plan.keyboardAudioPreferences)
        XCTAssertFalse(plan.removesOnlyRecord)
        let after = RememberedDisplayCleanup.applying(plan, to: settings)
        XCTAssertEqual(Array(after.keyboardAudioByDisplay.keys), [laptop.rawValue])

        let archive = SettingsArchive(createdAt: Date(timeIntervalSince1970: 0), appVersion: nil, settings: settings,
                                      favorites: FavoriteResolutions(), registry: RegistryState(), scenes: [],
                                      defaults: ArchivedDefaults())
        XCTAssertTrue(archive.referencedDisplayIDs.isSuperset(of: [desk, laptop]))
    }
}
