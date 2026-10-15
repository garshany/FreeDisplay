import XCTest
@testable import TopologyCore

/// SO-30: a shortcut macOS keeps for itself is named as such, whatever the registration says.
final class SystemShortcutReservationTests: XCTestCase {
    private let space: UInt32 = 0x31

    func testAnEnabledSystemShortcutIsAConflict() {
        let spotlight = SystemShortcutReservation.Chord(keyCode: space, modifiers: KeyBinding.command, enabled: true)
        XCTAssertEqual(SystemShortcutReservation.conflict(for: KeyBinding(keyCode: space, modifiers: KeyBinding.command),
                                                          among: [spotlight]), spotlight)
    }

    func testDisabledUnassignedAndDifferentChordsAreNot() {
        let binding = KeyBinding(keyCode: space, modifiers: KeyBinding.command)
        let off = SystemShortcutReservation.Chord(keyCode: space, modifiers: KeyBinding.command, enabled: false)
        let unassigned = SystemShortcutReservation.Chord(keyCode: SystemShortcutReservation.unassignedKeyCode,
                                                         modifiers: KeyBinding.command, enabled: true)
        let otherModifiers = SystemShortcutReservation.Chord(keyCode: space,
                                                             modifiers: KeyBinding.command | KeyBinding.option, enabled: true)
        XCTAssertNil(SystemShortcutReservation.conflict(for: binding, among: [off, unassigned, otherModifiers]))
    }

    func testFunctionAndKeypadFlagsDoNotHideAConflict() {
        // Mission Control's ⌃↑ is listed with the function-key flag (0x20000) set beside ⌃.
        let up: UInt32 = 0x7E
        let missionControl = SystemShortcutReservation.Chord(keyCode: up, modifiers: KeyBinding.control | 0x20000,
                                                             enabled: true)
        XCTAssertNotNil(SystemShortcutReservation.conflict(for: KeyBinding(keyCode: up, modifiers: KeyBinding.control),
                                                           among: [missionControl]))
    }
}
