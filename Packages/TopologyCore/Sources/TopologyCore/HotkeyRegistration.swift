import Foundation

/// One place a global chord can be bound (SO-30): a fixed action, or one of the user's input-switch
/// hotkeys. Conflict checks and registration status speak in slots so a chord taken by an input
/// hotkey is reported as precisely as one taken by an action.
public enum HotkeySlot: Hashable, Sendable {
    case action(HotkeyAction)
    case inputSwitch(id: String)
}

/// Whether a slot's chord is live right now, and if not, why (SO-30). Shown next to each shortcut so
/// a binding that macOS refused, or that another slot already holds, never looks like it works.
public enum HotkeyRegistrationStatus: Hashable, Sendable {
    /// No chord, and none shipped for this action.
    case unassigned
    /// The user removed the chord (a shipped default included) — it stays off until set or restored.
    case cleared
    /// macOS accepted the registration. That is all it promises: a chord macOS keeps for itself, or
    /// one another app also listens for, can still fail to reach OpenDisplay.
    case registered
    /// Not registered: `holder` claimed the same chord first.
    case conflict(holder: HotkeySlot)
    /// macOS refused the registration (for example, the chord is already registered elsewhere).
    case failed
    /// Every shortcut is unregistered while a new one is being recorded, so the keys typed into the
    /// recorder can't fire an action.
    case paused
}

/// The chords to register for an effective registry, decided before any OS call (SO-30): actions
/// first in list order, then input-switch hotkeys in their saved order, and a chord already claimed
/// earlier in the pass is reported as a conflict instead of being registered twice — the second
/// Carbon registration of one chord would fail anyway, and "failed" would misdescribe it.
public struct HotkeyRegistrationPlan: Hashable, Sendable {
    public struct Registration: Hashable, Sendable {
        public var slot: HotkeySlot
        public var binding: KeyBinding
    }

    public private(set) var registrations: [Registration] = []
    /// Each slot that lost its chord to an earlier one, with the slot that holds it.
    public private(set) var conflicts: [HotkeySlot: HotkeySlot] = [:]
    private let cleared: Set<HotkeyAction>

    /// - Parameter registry: the effective registry (`KeyboardShortcutRegistry.effective`).
    public init(registry: KeyboardShortcutRegistry) {
        cleared = registry.disabledActions
        var holders: [KeyBinding: HotkeySlot] = [:]
        func claim(_ slot: HotkeySlot, _ binding: KeyBinding) {
            if let holder = holders[binding] {
                conflicts[slot] = holder
            } else {
                holders[binding] = slot
                registrations.append(Registration(slot: slot, binding: binding))
            }
        }
        for action in HotkeyAction.allCases {
            if let binding = registry.binding(for: action) { claim(.action(action), binding) }
        }
        for entry in registry.inputSwitchBindings { claim(.inputSwitch(id: entry.id), entry.binding) }
        // The merge leaves an action without its shipped chord when a saved binding already uses it
        // (`KeyboardShortcutRegistry.mergedWithDefaults`); say who holds it instead of "no shortcut".
        for action in HotkeyAction.allCases where registry.binding(for: action) == nil && !cleared.contains(action) {
            if let shipped = action.defaultBinding, let holder = holders[shipped] { conflicts[.action(action)] = holder }
        }
    }

    /// The status to show for one action, given which planned registrations macOS refused and whether
    /// registration is paused for recording.
    public func status(for action: HotkeyAction, failed: Set<HotkeySlot>, paused: Bool) -> HotkeyRegistrationStatus {
        status(for: .action(action), failed: failed, paused: paused, cleared: cleared.contains(action))
    }

    /// The status of an input-switch hotkey, by its id.
    public func status(forInputSwitch id: String, failed: Set<HotkeySlot>, paused: Bool) -> HotkeyRegistrationStatus {
        status(for: .inputSwitch(id: id), failed: failed, paused: paused, cleared: false)
    }

    private func status(for slot: HotkeySlot, failed: Set<HotkeySlot>, paused: Bool,
                        cleared: Bool) -> HotkeyRegistrationStatus {
        if let holder = conflicts[slot] { return .conflict(holder: holder) }
        guard registrations.contains(where: { $0.slot == slot }) else { return cleared ? .cleared : .unassigned }
        if paused { return .paused }
        return failed.contains(slot) ? .failed : .registered
    }
}

/// What one key press means to the shortcut recorder (SO-30). Pure, so the rules are tested here and
/// the AppKit recorder only translates events in and acts on the verdict.
public enum HotkeyRecorderPolicy {
    public enum Verdict: Hashable, Sendable {
        /// Save this chord.
        case accept(KeyBinding)
        /// Escape: stop recording and keep the old chord.
        case cancel
        /// Delete / Forward Delete: remove the chord.
        case clear
        /// Tab or ⇧Tab: recording ends and the key moves focus as usual.
        case endAndPassThrough
        /// A key that can't be a global shortcut on its own (a letter with no modifier, or with Shift
        /// only): keep recording and tell the user.
        case reject
    }

    public static let escapeKeyCode: UInt32 = 0x35
    public static let deleteKeyCode: UInt32 = 0x33
    public static let forwardDeleteKeyCode: UInt32 = 0x75
    public static let tabKeyCode: UInt32 = 0x30

    /// F1–F20 by Carbon virtual key code. These may be bound alone, since no app types them as text.
    public static let functionKeyCodes: [UInt32] = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,  // F1–F10
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,  // F11–F20
    ]

    /// - Parameters:
    ///   - keyCode: the Carbon virtual key code of the pressed key.
    ///   - modifiers: the Carbon modifier mask (`KeyBinding.command` etc.) held with it.
    public static func verdict(keyCode: UInt32, modifiers: UInt32) -> Verdict {
        let modifiers = modifiers & KeyBinding.recordableModifiers
        // Tab and ⇧Tab move focus forwards and back; either ends recording.
        if keyCode == tabKeyCode, modifiers & ~KeyBinding.shift == 0 { return .endAndPassThrough }
        if modifiers == 0 {
            switch keyCode {
            case escapeKeyCode: return .cancel
            case deleteKeyCode, forwardDeleteKeyCode: return .clear
            default: break
            }
        }
        let binding = KeyBinding(keyCode: keyCode, modifiers: modifiers)
        if functionKeyCodes.contains(keyCode) { return .accept(binding) }
        // Shift alone only changes which character a key types; the chord would steal ordinary
        // typing from every app.
        let chordModifiers = KeyBinding.command | KeyBinding.option | KeyBinding.control
        return modifiers & chordModifiers != 0 ? .accept(binding) : .reject
    }

    /// True for ⌘-letter style chords without ⌃ or ⌥: those are what app menus use (⌘C, ⌘W…), and a
    /// global registration takes the chord away from every app while OpenDisplay runs.
    public static func mayShadowAppMenus(_ binding: KeyBinding) -> Bool {
        guard !functionKeyCodes.contains(binding.keyCode) else { return false }
        return binding.modifiers & KeyBinding.command != 0
            && binding.modifiers & (KeyBinding.control | KeyBinding.option) == 0
    }
}

extension KeyBinding {
    /// The modifiers a recorded chord can carry; Caps Lock and the Fn/arrow flags are not part of a
    /// Carbon hotkey.
    public static let recordableModifiers: UInt32 = command | shift | option | control
}

/// Writes a chord the way macOS menus do: modifiers in ⌃⌥⇧⌘ order, then the key (SO-30). Key names
/// follow the U.S. layout's key positions, which is what a Carbon key code identifies.
public enum KeyBindingFormatter {
    public static func string(for binding: KeyBinding) -> String {
        var text = ""
        if binding.modifiers & KeyBinding.control != 0 { text += "\u{2303}" }
        if binding.modifiers & KeyBinding.option != 0 { text += "\u{2325}" }
        if binding.modifiers & KeyBinding.shift != 0 { text += "\u{21E7}" }
        if binding.modifiers & KeyBinding.command != 0 { text += "\u{2318}" }
        return text + keyName(binding.keyCode)
    }

    public static func keyName(_ keyCode: UInt32) -> String {
        if let index = HotkeyRecorderPolicy.functionKeyCodes.firstIndex(of: keyCode) { return "F\(index + 1)" }
        return names[keyCode] ?? "#\(keyCode)"
    }

    private static let names: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0A: "§", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5",
        0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O",
        0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x24: "\u{21A9}", 0x25: "L", 0x26: "J", 0x27: "'",
        0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".",
        0x30: "\u{21E5}", 0x31: "Space", 0x32: "`", 0x33: "\u{232B}", 0x35: "\u{238B}",
        0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +", 0x47: "\u{2327}", 0x4B: "Keypad /",
        0x4C: "\u{2324}", 0x4E: "Keypad -", 0x51: "Keypad =", 0x52: "Keypad 0", 0x53: "Keypad 1",
        0x54: "Keypad 2", 0x55: "Keypad 3", 0x56: "Keypad 4", 0x57: "Keypad 5", 0x58: "Keypad 6",
        0x59: "Keypad 7", 0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x72: "Help", 0x73: "\u{2196}", 0x74: "\u{21DE}", 0x75: "\u{2326}", 0x77: "\u{2198}",
        0x79: "\u{21DF}", 0x7B: "\u{2190}", 0x7C: "\u{2192}", 0x7D: "\u{2193}", 0x7E: "\u{2191}",
    ]
}
