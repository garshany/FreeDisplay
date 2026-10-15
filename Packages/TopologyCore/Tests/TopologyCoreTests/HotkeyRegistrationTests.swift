import DisplayDomain
import XCTest
@testable import TopologyCore

final class HotkeyRegistrationTests: XCTestCase {
    private let ctrlOptCmdR = KeyBinding(keyCode: 0x0F, modifiers: KeyBinding.controlOptionCommand)
    private let shiftF1 = KeyBinding(keyCode: 0x7A, modifiers: KeyBinding.shift)
    private let shiftF2 = KeyBinding(keyCode: 0x78, modifiers: KeyBinding.shift)
    private let ctrlOptCmdUp = KeyBinding(keyCode: 0x7E, modifiers: KeyBinding.controlOptionCommand)
    private let desk = DisplayRecordID(rawValue: "disp_desk")

    // MARK: - Effective registry (defaults + explicit "off" + legacy switch)

    func testEffectiveRegistryFoldsInTheLegacyReconnectSwitch() {
        let on = KeyboardShortcutRegistry().effective(reconnectAllEnabled: true)
        XCTAssertEqual(on.binding(for: .reconnectAll), ctrlOptCmdR)
        let off = KeyboardShortcutRegistry().effective(reconnectAllEnabled: false)
        XCTAssertNil(off.binding(for: .reconnectAll))
        XCTAssertTrue(off.disabledActions.contains(.reconnectAll))
        XCTAssertEqual(off.binding(for: .brightnessUp), shiftF2)  // nothing else changes
    }

    func testNewActionsShipUnbound() {
        let defaults = KeyboardShortcutRegistry.defaults
        for action in [HotkeyAction.brightnessUpFine, .brightnessDownFine, .toggleMenu, .openSettings, .quit] {
            XCTAssertNil(defaults.binding(for: action), "\(action) must not take a chord nobody chose")
        }
    }

    func testSlotLookupFindsActionsAndInputHotkeys() {
        var registry = KeyboardShortcutRegistry()
        let input = InputSwitchBinding(id: "in-1", displayID: desk, inputCode: 0x11, binding: ctrlOptCmdUp)
        registry.addInputSwitchBinding(input)
        let effective = registry.effective(reconnectAllEnabled: true)
        XCTAssertEqual(effective.slot(using: ctrlOptCmdR), .action(.reconnectAll))
        XCTAssertEqual(effective.slot(using: ctrlOptCmdUp), .inputSwitch(id: "in-1"))
        XCTAssertNil(effective.slot(using: ctrlOptCmdR, excluding: .action(.reconnectAll)))
        XCTAssertNil(effective.slot(using: KeyBinding(keyCode: 0x00, modifiers: KeyBinding.command)))
    }

    func testAClearedShippedChordIsFreeForAnotherAction() {
        var registry = KeyboardShortcutRegistry()
        registry.setBinding(nil, for: .brightnessUp)
        XCTAssertNil(registry.effective(reconnectAllEnabled: true).slot(using: shiftF2))
    }

    // MARK: - Registration plan and status

    func testPlanRegistersEveryBoundSlotOnce() {
        var registry = KeyboardShortcutRegistry()
        registry.addInputSwitchBinding(InputSwitchBinding(id: "in-1", displayID: desk, inputCode: 0x11, binding: ctrlOptCmdUp))
        let plan = HotkeyRegistrationPlan(registry: registry.effective(reconnectAllEnabled: true))
        XCTAssertEqual(plan.registrations.map(\.slot),
                       [.action(.reconnectAll), .action(.brightnessUp), .action(.brightnessDown), .inputSwitch(id: "in-1")])
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.status(for: .reconnectAll, failed: [], paused: false), .registered)
        XCTAssertEqual(plan.status(forInputSwitch: "in-1", failed: [], paused: false), .registered)
    }

    func testDuplicateChordGoesToTheEarlierSlotAndTheLaterOneIsAConflict() {
        // Every chord here is the user's own choice (a saved file can hold such duplicates; Settings
        // itself refuses to save one), so the plan's order alone decides who keeps it. A default
        // never competes with a saved chord: see `testASavedBindingKeepsItsChordOverANewerDefault`.
        var registry = KeyboardShortcutRegistry()
        registry.setBinding(ctrlOptCmdR, for: .reconnectAll)
        registry.setBinding(ctrlOptCmdR, for: .faceLight)
        registry.setBinding(shiftF1, for: .brightnessDown)
        registry.addInputSwitchBinding(InputSwitchBinding(id: "in-1", displayID: desk, inputCode: 0x11, binding: shiftF1))
        let plan = HotkeyRegistrationPlan(registry: registry.effective(reconnectAllEnabled: true))
        XCTAssertEqual(plan.registrations.filter { $0.binding == ctrlOptCmdR }.map(\.slot), [.action(.reconnectAll)])
        XCTAssertEqual(plan.status(for: .faceLight, failed: [], paused: false),
                       .conflict(holder: .action(.reconnectAll)))
        XCTAssertEqual(plan.status(forInputSwitch: "in-1", failed: [], paused: false),
                       .conflict(holder: .action(.brightnessDown)))
        XCTAssertEqual(plan.status(for: .reconnectAll, failed: [], paused: false), .registered)
    }

    func testASavedBindingKeepsItsChordOverANewerDefault() throws {
        // R3 #1: a file from before ⇧F1 became Brightness Down's default, with ⇧F1 on FaceLight.
        // FaceLight keeps working; Brightness Down says who holds its standard chord.
        let old = #"{"bindings":{"faceLight":{"keyCode":122,"modifiers":512}},"inputSwitchBindings":[]}"#
        let registry = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: Data(old.utf8))
        let plan = HotkeyRegistrationPlan(registry: registry.effective(reconnectAllEnabled: true))
        XCTAssertEqual(plan.registrations.filter { $0.binding == shiftF1 }.map(\.slot), [.action(.faceLight)])
        XCTAssertEqual(plan.status(for: .faceLight, failed: [], paused: false), .registered)
        XCTAssertEqual(plan.status(for: .brightnessDown, failed: [], paused: false),
                       .conflict(holder: .action(.faceLight)))
        XCTAssertEqual(plan.status(for: .brightnessUp, failed: [], paused: false), .registered)
    }

    func testAnInputHotkeyKeepsItsChordOverADefault() {
        var registry = KeyboardShortcutRegistry()
        registry.addInputSwitchBinding(InputSwitchBinding(id: "in-1", displayID: desk, inputCode: 0x11, binding: shiftF1))
        let plan = HotkeyRegistrationPlan(registry: registry.effective(reconnectAllEnabled: true))
        XCTAssertEqual(plan.status(forInputSwitch: "in-1", failed: [], paused: false), .registered)
        XCTAssertEqual(plan.status(for: .brightnessDown, failed: [], paused: false),
                       .conflict(holder: .inputSwitch(id: "in-1")))
    }

    func testAReconnectChordTheLegacySwitchTurnsOffDoesNotBlockADefault() {
        var registry = KeyboardShortcutRegistry()
        registry.setBinding(shiftF1, for: .reconnectAll)
        let off = registry.effective(reconnectAllEnabled: false)
        XCTAssertNil(off.binding(for: .reconnectAll))
        XCTAssertEqual(off.binding(for: .brightnessDown), shiftF1)
        let on = registry.effective(reconnectAllEnabled: true)
        XCTAssertEqual(on.binding(for: .reconnectAll), shiftF1)
        XCTAssertNil(on.binding(for: .brightnessDown))
    }

    func testAClearedActionWhoseDefaultIsTakenStillReadsAsCleared() {
        var registry = KeyboardShortcutRegistry()
        registry.setBinding(nil, for: .brightnessDown)
        registry.setBinding(shiftF1, for: .faceLight)
        let plan = HotkeyRegistrationPlan(registry: registry.effective(reconnectAllEnabled: true))
        XCTAssertEqual(plan.status(for: .brightnessDown, failed: [], paused: false), .cleared)
        XCTAssertEqual(plan.status(for: .faceLight, failed: [], paused: false), .registered)
    }

    func testStatusSeparatesClearedUnassignedFailedAndPaused() {
        var registry = KeyboardShortcutRegistry()
        registry.setBinding(nil, for: .brightnessDown)
        let plan = HotkeyRegistrationPlan(registry: registry.effective(reconnectAllEnabled: true))
        XCTAssertEqual(plan.status(for: .brightnessDown, failed: [], paused: false), .cleared)
        XCTAssertEqual(plan.status(for: .faceLight, failed: [], paused: false), .unassigned)
        XCTAssertEqual(plan.status(for: .brightnessUp, failed: [.action(.brightnessUp)], paused: false), .failed)
        XCTAssertEqual(plan.status(for: .brightnessUp, failed: [], paused: true), .paused)
        // Pausing doesn't turn an unbound action into a live-looking one.
        XCTAssertEqual(plan.status(for: .faceLight, failed: [], paused: true), .unassigned)
    }

    func testLegacySwitchOffReadsAsCleared() {
        let plan = HotkeyRegistrationPlan(registry: KeyboardShortcutRegistry().effective(reconnectAllEnabled: false))
        XCTAssertEqual(plan.status(for: .reconnectAll, failed: [], paused: false), .cleared)
        XCTAssertFalse(plan.registrations.contains { $0.slot == .action(.reconnectAll) })
    }

    func testClearingSurvivesSaveReloadAndReRegistration() throws {
        // SO-01 at the registration boundary: the plan built from a reloaded file leaves it out.
        var registry = KeyboardShortcutRegistry()
        registry.setBinding(nil, for: .brightnessUp)
        let reloaded = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: JSONEncoder().encode(registry))
        let plan = HotkeyRegistrationPlan(registry: reloaded.effective(reconnectAllEnabled: true))
        XCTAssertFalse(plan.registrations.contains { $0.slot == .action(.brightnessUp) })
        XCTAssertEqual(plan.status(for: .brightnessUp, failed: [], paused: false), .cleared)
        // Restoring is a separate, explicit step.
        var restored = reloaded
        restored.restoreDefault(for: .brightnessUp)
        let replanned = HotkeyRegistrationPlan(registry: restored.effective(reconnectAllEnabled: true))
        XCTAssertEqual(replanned.status(for: .brightnessUp, failed: [], paused: false), .registered)
    }

    // MARK: - Recorder key handling

    func testRecorderControlKeys() {
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x35, modifiers: 0), .cancel)
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x33, modifiers: 0), .clear)
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x75, modifiers: 0), .clear)
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x30, modifiers: 0), .endAndPassThrough)
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x30, modifiers: KeyBinding.shift), .endAndPassThrough)
        // With a real modifier Tab is an ordinary chord.
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x30, modifiers: KeyBinding.control),
                       .accept(KeyBinding(keyCode: 0x30, modifiers: KeyBinding.control)))
    }

    func testRecorderAcceptsChordsWithARealModifier() {
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x0F, modifiers: KeyBinding.controlOptionCommand),
                       .accept(ctrlOptCmdR))
        // Escape/Delete with a modifier are ordinary chords, not recorder commands.
        let optionDelete = KeyBinding(keyCode: 0x33, modifiers: KeyBinding.option)
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x33, modifiers: KeyBinding.option), .accept(optionDelete))
    }

    func testRecorderRejectsBareAndShiftOnlyKeys() {
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x00, modifiers: 0), .reject)
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x00, modifiers: KeyBinding.shift), .reject)
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x24, modifiers: 0), .reject)  // Return
    }

    func testRecorderAcceptsFunctionKeysAloneOrWithShift() {
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x7A, modifiers: 0), .accept(KeyBinding(keyCode: 0x7A, modifiers: 0)))
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x7A, modifiers: KeyBinding.shift), .accept(shiftF1))
    }

    func testRecorderDropsCapsLockFromTheChord() {
        let capsLock: UInt32 = 0x0400
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x0F, modifiers: KeyBinding.controlOptionCommand | capsLock),
                       .accept(ctrlOptCmdR))
        XCTAssertEqual(HotkeyRecorderPolicy.verdict(keyCode: 0x35, modifiers: capsLock), .cancel)
    }

    func testCommandOnlyChordsAreFlaggedAsShadowingAppMenus() {
        XCTAssertTrue(HotkeyRecorderPolicy.mayShadowAppMenus(KeyBinding(keyCode: 0x08, modifiers: KeyBinding.command)))
        XCTAssertTrue(HotkeyRecorderPolicy.mayShadowAppMenus(KeyBinding(keyCode: 0x08, modifiers: KeyBinding.command | KeyBinding.shift)))
        XCTAssertFalse(HotkeyRecorderPolicy.mayShadowAppMenus(ctrlOptCmdR))
        XCTAssertFalse(HotkeyRecorderPolicy.mayShadowAppMenus(KeyBinding(keyCode: 0x7A, modifiers: KeyBinding.command)))
    }

    // MARK: - Formatting

    func testFormatterUsesMenuModifierOrder() {
        XCTAssertEqual(KeyBindingFormatter.string(for: ctrlOptCmdR), "⌃⌥⌘R")
        XCTAssertEqual(KeyBindingFormatter.string(for: shiftF1), "⇧F1")
        let all = KeyBinding(keyCode: 0x7E, modifiers: KeyBinding.command | KeyBinding.shift | KeyBinding.option | KeyBinding.control)
        XCTAssertEqual(KeyBindingFormatter.string(for: all), "⌃⌥⇧⌘↑")
        XCTAssertEqual(KeyBindingFormatter.keyName(0x5A), "F20")
        XCTAssertEqual(KeyBindingFormatter.keyName(0x12), "1")
        XCTAssertEqual(KeyBindingFormatter.keyName(0xFF), "#255")  // unknown keys stay identifiable
    }
}

/// Owner decision #26: ⌃⌥⌘R belongs to Reconnect All while its shortcut is on.
final class RecoveryChordReservationTests: XCTestCase {
    private let recovery = KeyboardShortcutRegistry.recoveryChord
    private let other = KeyBinding(keyCode: 0x07, modifiers: KeyBinding.controlOptionCommand)  // ⌃⌥⌘X

    func testTheRecoveryChordIsReconnectAllsDefault() {
        XCTAssertEqual(HotkeyAction.reconnectAll.defaultBinding, recovery)
        XCTAssertEqual(KeyBindingFormatter.string(for: recovery), "⌃⌥⌘R")
    }

    func testNoOtherActionOrInputHotkeyMayTakeIt() {
        let registry = KeyboardShortcutRegistry.defaults.effective(reconnectAllEnabled: true)
        for action in HotkeyAction.allCases where action != .reconnectAll {
            XCTAssertTrue(registry.isReservedForRecovery(recovery, slot: .action(action)), "\(action)")
        }
        XCTAssertTrue(registry.isReservedForRecovery(recovery, slot: .inputSwitch(id: "x")))
        XCTAssertFalse(registry.isReservedForRecovery(recovery, slot: .action(.reconnectAll)))
        XCTAssertFalse(registry.isReservedForRecovery(other, slot: .action(.faceLight)))
    }

    func testStillReservedWhenReconnectAllUsesAnotherChord() {
        var saved = KeyboardShortcutRegistry.defaults
        saved.setBinding(other, for: .reconnectAll)
        XCTAssertTrue(saved.effective(reconnectAllEnabled: true).isReservedForRecovery(recovery, slot: .action(.faceLight)))
    }

    func testFreeOnceTheRecoveryShortcutIsOff() {
        XCTAssertFalse(KeyboardShortcutRegistry.defaults.effective(reconnectAllEnabled: false)
            .isReservedForRecovery(recovery, slot: .action(.faceLight)))
        var cleared = KeyboardShortcutRegistry.defaults
        cleared.setBinding(nil, for: .reconnectAll)
        XCTAssertFalse(cleared.effective(reconnectAllEnabled: true).isReservedForRecovery(recovery, slot: .action(.faceLight)))
    }

    func testASavedBindingOnTheChordNeverTakesItFromReconnectAll() throws {
        // A file saved before the reservation, with FaceLight on ⌃⌥⌘R.
        let file = #"{"bindings":{"faceLight":{"keyCode":15,"modifiers":6400}},"inputSwitchBindings":[]}"#
        let saved = try JSONDecoder().decode(KeyboardShortcutRegistry.self, from: Data(file.utf8))
        let effective = saved.effective(reconnectAllEnabled: true)
        XCTAssertEqual(effective.binding(for: .reconnectAll), recovery)
        let plan = HotkeyRegistrationPlan(registry: effective)
        XCTAssertEqual(plan.registrations.filter { $0.binding == recovery }.map(\.slot), [.action(.reconnectAll)])
        XCTAssertEqual(plan.status(for: .faceLight, failed: [], paused: false), .conflict(holder: .action(.reconnectAll)))
        XCTAssertEqual(plan.status(for: .reconnectAll, failed: [], paused: false), .registered)
    }

    func testAnOldBindingOnTheChordRegistersNothingWhileReconnectAllUsesAnotherOne() throws {
        var saved = KeyboardShortcutRegistry.defaults
        saved.setBinding(other, for: .reconnectAll)
        saved.setBinding(recovery, for: .faceLight)  // as an older build could have saved it
        let plan = HotkeyRegistrationPlan(registry: saved.effective(reconnectAllEnabled: true))
        XCTAssertTrue(plan.registrations.filter { $0.binding == recovery }.isEmpty)
        XCTAssertEqual(plan.status(for: .faceLight, failed: [], paused: false), .conflict(holder: .action(.reconnectAll)))
        XCTAssertEqual(plan.status(for: .reconnectAll, failed: [], paused: false), .registered)
    }

    func testWithRecoveryOffTheChordWorksForAnotherAction() {
        var saved = KeyboardShortcutRegistry.defaults
        saved.setBinding(nil, for: .reconnectAll)
        saved.setBinding(recovery, for: .faceLight)
        let plan = HotkeyRegistrationPlan(registry: saved.effective(reconnectAllEnabled: true))
        XCTAssertEqual(plan.status(for: .faceLight, failed: [], paused: false), .registered)
    }
}
