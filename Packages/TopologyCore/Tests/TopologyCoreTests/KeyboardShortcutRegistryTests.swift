import DisplayDomain
import XCTest
@testable import TopologyCore

final class KeyboardShortcutRegistryTests: XCTestCase {
    private let r = KeyBinding(keyCode: 0x0F, modifiers: KeyBinding.controlOptionCommand)
    private let up = KeyBinding(keyCode: 0x7E, modifiers: KeyBinding.controlOptionCommand)   // arrow up
    private let digit1 = KeyBinding(keyCode: 0x12, modifiers: KeyBinding.controlOptionCommand)
    private let digit2 = KeyBinding(keyCode: 0x13, modifiers: KeyBinding.controlOptionCommand)
    private let deskMonitor = DisplayRecordID(rawValue: "disp_desk")
    private let laptopMonitor = DisplayRecordID(rawValue: "disp_laptop")

    func testDefaultsBindReconnectAllToCtrlOptCmdR() {
        let defaults = KeyboardShortcutRegistry.defaults
        XCTAssertEqual(defaults.binding(for: .reconnectAll), r)
        XCTAssertEqual(defaults.binding(for: .brightnessUp), KeyBinding(keyCode: 0x78, modifiers: KeyBinding.shift))
        XCTAssertNil(defaults.binding(for: .faceLight))      // unbound by default, same as brightnessUp
    }

    func testFaceLightHasABehaviorNamingLabel() {
        XCTAssertEqual(HotkeyAction.faceLight.label, "Toggle FaceLight")
    }

    func testControlOptionCommandMaskMatchesCarbon() {
        // cmd 0x100 | option 0x800 | control 0x1000 = 0x1900
        XCTAssertEqual(KeyBinding.controlOptionCommand, 0x1900)
    }

    func testSetAndClearBinding() {
        var reg = KeyboardShortcutRegistry()
        reg.setBinding(up, for: .brightnessUp)
        XCTAssertEqual(reg.binding(for: .brightnessUp), up)
        reg.setBinding(nil, for: .brightnessUp)
        XCTAssertNil(reg.binding(for: .brightnessUp))
    }

    func testReverseLookupByCombo() {
        var reg = KeyboardShortcutRegistry()
        reg.setBinding(r, for: .reconnectAll)
        XCTAssertEqual(reg.action(for: r), .reconnectAll)
        XCTAssertNil(reg.action(for: up))
    }

    func testConflictDetection() {
        var reg = KeyboardShortcutRegistry()
        reg.setBinding(r, for: .reconnectAll)
        XCTAssertTrue(reg.conflicts(r, excluding: nil))                 // r is taken
        XCTAssertFalse(reg.conflicts(r, excluding: .reconnectAll))      // ...but by reconnectAll itself
        XCTAssertFalse(reg.conflicts(up))                              // up is free
        reg.setBinding(r, for: .brightnessUp)                          // same combo, two actions
        XCTAssertEqual(reg.conflictingBindings()[r]?.sorted { $0.rawValue < $1.rawValue },
                       [.brightnessUp, .reconnectAll])
    }

    func testMergeOverDefaultsKeepsOverridesAndFillsGaps() {
        var reg = KeyboardShortcutRegistry()
        reg.setBinding(up, for: .reconnectAll)    // override the default reconnect chord
        let merged = reg.mergedWithDefaults()
        XCTAssertEqual(merged.binding(for: .reconnectAll), up)        // override wins
        XCTAssertEqual(merged.binding(for: .brightnessUp), KeyBinding(keyCode: 0x78, modifiers: KeyBinding.shift))
    }

    func testCodableRoundTripsIncludingUnknownKeyTolerance() throws {
        var reg = KeyboardShortcutRegistry()
        reg.setBinding(r, for: .reconnectAll)
        reg.setBinding(up, for: .brightnessUp)
        let data = try JSONEncoder().encode(reg)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: data), reg)
        // A future action key the current build doesn't know is ignored on decode (object form).
        let withUnknown = #"{"reconnectAll":{"keyCode":15,"modifiers":6400},"futureAction":{"keyCode":1,"modifiers":0}}"#
        let decoded = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: Data(withUnknown.utf8))
        XCTAssertEqual(decoded.binding(for: .reconnectAll), r)
        XCTAssertEqual(decoded.bindings.count, 1)  // futureAction dropped
        XCTAssertTrue(decoded.inputSwitchBindings.isEmpty)  // legacy shape never had these
    }

    func testAddAndRemoveInputSwitchBinding() {
        var reg = KeyboardShortcutRegistry()
        let entry = InputSwitchBinding(id: "hdmi2", displayID: deskMonitor, inputCode: 0x12, binding: digit1)
        reg.addInputSwitchBinding(entry)
        XCTAssertEqual(reg.inputSwitchBindings, [entry])

        // Adding again with the same id replaces rather than duplicating.
        let replacement = InputSwitchBinding(id: "hdmi2", displayID: deskMonitor, inputCode: 0x0F, binding: digit1)
        reg.addInputSwitchBinding(replacement)
        XCTAssertEqual(reg.inputSwitchBindings, [replacement])

        reg.removeInputSwitchBinding(id: "hdmi2")
        XCTAssertTrue(reg.inputSwitchBindings.isEmpty)
    }

    func testInputSwitchBindingConflictsWithFixedActionAndOtherInputSwitchBinding() {
        var reg = KeyboardShortcutRegistry()
        reg.setBinding(r, for: .reconnectAll)
        XCTAssertTrue(reg.inputSwitchBindingConflicts(r, excludingInputSwitchID: nil))    // clashes with reconnectAll
        XCTAssertFalse(reg.inputSwitchBindingConflicts(digit1, excludingInputSwitchID: nil))

        let hdmi2 = InputSwitchBinding(id: "hdmi2", displayID: deskMonitor, inputCode: 0x12, binding: digit1)
        reg.addInputSwitchBinding(hdmi2)
        XCTAssertTrue(reg.inputSwitchBindingConflicts(digit1, excludingInputSwitchID: nil))
        XCTAssertFalse(reg.inputSwitchBindingConflicts(digit1, excludingInputSwitchID: "hdmi2"))  // editing itself
        XCTAssertFalse(reg.inputSwitchBindingConflicts(digit2, excludingInputSwitchID: nil))       // free combo
    }

    func testInputSwitchBindingCodableRoundTrip() throws {
        var reg = KeyboardShortcutRegistry()
        reg.setBinding(r, for: .reconnectAll)
        reg.addInputSwitchBinding(InputSwitchBinding(id: "hdmi2", displayID: deskMonitor, inputCode: 0x12, binding: digit1))
        reg.addInputSwitchBinding(InputSwitchBinding(id: "dp1", displayID: laptopMonitor, inputCode: 0x0F, binding: digit2))
        let data = try JSONEncoder().encode(reg)
        let decoded = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: data)
        XCTAssertEqual(decoded, reg)
        XCTAssertEqual(decoded.inputSwitchBindings.count, 2)
    }

    // MARK: Clearing a shipped shortcut (SO-01)

    private let shiftF2 = KeyBinding(keyCode: 0x78, modifiers: KeyBinding.shift)

    func testClearedDefaultStaysUnboundThroughTheMerge() {
        var reg = KeyboardShortcutRegistry.defaults
        reg.setBinding(nil, for: .brightnessUp)
        XCTAssertNil(reg.mergedWithDefaults().binding(for: .brightnessUp),
                     "the merge over defaults must not resurrect a shortcut the user cleared")
        XCTAssertEqual(reg.mergedWithDefaults().binding(for: .reconnectAll), r)  // untouched defaults remain
    }

    func testClearedDefaultSurvivesSaveAndReload() throws {
        var reg = KeyboardShortcutRegistry.defaults
        reg.setBinding(nil, for: .brightnessUp)
        let decoded = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: JSONEncoder().encode(reg))
        XCTAssertEqual(decoded, reg)
        XCTAssertNil(decoded.mergedWithDefaults().binding(for: .brightnessUp))
    }

    func testRebindingAClearedActionLiftsTheTombstone() {
        var reg = KeyboardShortcutRegistry.defaults
        reg.setBinding(nil, for: .brightnessUp)
        reg.setBinding(up, for: .brightnessUp)
        XCTAssertEqual(reg.mergedWithDefaults().binding(for: .brightnessUp), up)
        XCTAssertFalse(reg.disabledActions.contains(.brightnessUp))
    }

    func testRestoringDefaultsIsSeparateFromClearing() {
        var reg = KeyboardShortcutRegistry.defaults
        reg.setBinding(nil, for: .brightnessUp)
        reg.setBinding(up, for: .reconnectAll)
        let entry = InputSwitchBinding(id: "hdmi2", displayID: deskMonitor, inputCode: 0x12, binding: digit1)
        reg.addInputSwitchBinding(entry)

        var one = reg
        one.restoreDefault(for: .brightnessUp)
        XCTAssertEqual(one.mergedWithDefaults().binding(for: .brightnessUp), shiftF2)
        XCTAssertEqual(one.mergedWithDefaults().binding(for: .reconnectAll), up)  // only that action

        let all = reg.restoringDefaults()
        XCTAssertEqual(all.mergedWithDefaults().binding(for: .brightnessUp), shiftF2)
        XCTAssertEqual(all.mergedWithDefaults().binding(for: .reconnectAll), r)
        XCTAssertTrue(all.disabledActions.isEmpty)
        XCTAssertEqual(all.inputSwitchBindings, [entry])  // the user's own bindings have no default
    }

    func testFilesWithoutTheDisabledStateDecodeWithNone() throws {
        let current = #"{"bindings":{"reconnectAll":{"keyCode":15,"modifiers":6400}},"inputSwitchBindings":[]}"#
        XCTAssertTrue(try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: Data(current.utf8))
            .disabledActions.isEmpty)
        let withUnknown = #"{"bindings":{},"inputSwitchBindings":[],"disabledActions":["brightnessUp","futureAction"]}"#
        XCTAssertEqual(try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: Data(withUnknown.utf8))
            .disabledActions, [.brightnessUp])
    }

    // MARK: Defaults added by a later release (R3 #1)

    private let shiftF1 = KeyBinding(keyCode: 0x7A, modifiers: KeyBinding.shift)

    func testANewDefaultDoesNotTakeAChordTheUserAlreadyAssigned() throws {
        // A settings file from before Shift-F1/F2 shipped as the brightness defaults, with the user's
        // own Shift-F1 on FaceLight.
        let old = #"{"bindings":{"faceLight":{"keyCode":122,"modifiers":512}},"inputSwitchBindings":[]}"#
        let reg = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: Data(old.utf8))
        let merged = reg.mergedWithDefaults()
        XCTAssertEqual(merged.binding(for: .faceLight), shiftF1, "the user's own binding must survive the upgrade")
        XCTAssertNil(merged.binding(for: .brightnessDown), "the default whose chord is taken is skipped")
        XCTAssertFalse(merged.disabledActions.contains(.brightnessDown), "skipped, not cleared by the user")
        XCTAssertEqual(merged.binding(for: .brightnessUp), shiftF2)  // a free default still applies
        XCTAssertEqual(merged.binding(for: .reconnectAll), r)
        XCTAssertTrue(merged.conflictingBindings().isEmpty)
    }

    func testANewDefaultDoesNotTakeAChordOfALegacyFlatFile() throws {
        let legacy = #"{"faceLight":{"keyCode":122,"modifiers":512}}"#
        let reg = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: Data(legacy.utf8))
        XCTAssertEqual(reg.mergedWithDefaults().binding(for: .faceLight), shiftF1)
        XCTAssertNil(reg.mergedWithDefaults().binding(for: .brightnessDown))
    }

    func testANewDefaultDoesNotTakeAnInputHotkeyChord() {
        var reg = KeyboardShortcutRegistry()
        let entry = InputSwitchBinding(id: "hdmi2", displayID: deskMonitor, inputCode: 0x12, binding: shiftF1)
        reg.addInputSwitchBinding(entry)
        let merged = reg.mergedWithDefaults()
        XCTAssertNil(merged.binding(for: .brightnessDown))
        XCTAssertEqual(merged.slot(using: shiftF1), .inputSwitch(id: "hdmi2"))
    }

    func testAChordOfAClearedActionDoesNotBlockADefault() throws {
        // A binding stored for an action the user also cleared is not in force, so it holds no chord.
        let file = #"{"bindings":{"faceLight":{"keyCode":122,"modifiers":512}},"inputSwitchBindings":[],"disabledActions":["faceLight"]}"#
        let reg = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: Data(file.utf8))
        XCTAssertNil(reg.mergedWithDefaults().binding(for: .faceLight))
        XCTAssertEqual(reg.mergedWithDefaults().binding(for: .brightnessDown), shiftF1)
    }

    func testMergedWithDefaultsCarriesInputSwitchBindingsThrough() {
        var reg = KeyboardShortcutRegistry()
        let entry = InputSwitchBinding(id: "hdmi2", displayID: deskMonitor, inputCode: 0x12, binding: digit1)
        reg.addInputSwitchBinding(entry)
        XCTAssertEqual(reg.mergedWithDefaults().inputSwitchBindings, [entry])
    }
}
