import Foundation

/// The keyboard shortcuts macOS keeps for itself (SO-30): Spotlight, Mission Control, screenshots,
/// input sources and the rest of System Settings › Keyboard › Keyboard Shortcuts. A global hotkey
/// registered on one of these is usually accepted, yet macOS acts on the keys first — so a recorder
/// that only reported the registration would say "Registered" for a shortcut that never arrives.
public enum SystemShortcutReservation {
    /// One system shortcut as macOS lists it: a Carbon key code and Carbon modifier mask, as in
    /// `KeyBinding`, and whether it is switched on.
    public struct Chord: Hashable, Sendable {
        public var keyCode: UInt32
        public var modifiers: UInt32
        public var enabled: Bool

        public init(keyCode: UInt32, modifiers: UInt32, enabled: Bool) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.enabled = enabled
        }
    }

    /// The key code macOS lists for a system shortcut that has no key assigned.
    public static let unassignedKeyCode: UInt32 = 0xFFFF

    /// The switched-on system shortcut that uses `binding`'s keys, if one does. Modifiers are
    /// compared by the four a binding can hold: macOS also flags function and keypad keys, and those
    /// flags describe the key, not a different chord.
    public static func conflict(for binding: KeyBinding, among system: [Chord]) -> Chord? {
        let wanted = binding.modifiers & KeyBinding.recordableModifiers
        return system.first { chord in
            chord.enabled && chord.keyCode != unassignedKeyCode && chord.keyCode == binding.keyCode
                && chord.modifiers & KeyBinding.recordableModifiers == wanted
        }
    }
}
