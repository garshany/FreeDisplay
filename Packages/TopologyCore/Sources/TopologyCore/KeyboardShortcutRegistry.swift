import DisplayDomain
import Foundation

/// An app action a global keyboard shortcut can trigger (Batch-2 #4). The raw value is the stable
/// serialization key; case order is the order Settings lists the actions in and the order
/// registration claims chords (an earlier action keeps a chord a later one duplicates).
public enum HotkeyAction: String, Hashable, Sendable, Codable, CaseIterable {
    case reconnectAll
    case cycleMainDisplay
    case brightnessUp
    case brightnessDown
    /// One fine step (SO-29) — always fine, whatever the native keys' fine-by-default setting says.
    case brightnessUpFine
    case brightnessDownFine
    case faceLight
    /// Opens or closes the menu-bar panel (SO-38).
    case toggleMenu
    /// Opens the Settings window (SO-38).
    case openSettings
    /// Quits through the app's normal termination path, so quit-time restoration still runs (SO-38).
    case quit
    case toggleConsole
    case restart
    case softwareContrastUp
    case softwareContrastDown
    case softwareContrastUpFine
    case softwareContrastDownFine
    case warmer
    case cooler
    case resetSoftwareAdjustments
    case toggleSoftwareAdjustments
    case volumeUp
    case volumeDown
    case volumeUpFine
    case volumeDownFine
    case toggleMute
    case mute
    case unmute

    public var label: String {
        switch self {
        case .reconnectAll: return "Reconnect All Displays"
        case .cycleMainDisplay: return "Cycle Main Display"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        case .brightnessUpFine: return "Brightness Up (Fine)"
        case .brightnessDownFine: return "Brightness Down (Fine)"
        case .faceLight: return "Toggle FaceLight"
        case .toggleMenu: return "Show or Hide the Menu"
        case .openSettings: return "Open Settings"
        case .quit: return "Quit FreeDisplay"
        case .toggleConsole: return "Show or Hide the Console"
        case .restart: return "Restart FreeDisplay"
        case .softwareContrastUp: return "Software Contrast Up"
        case .softwareContrastDown: return "Software Contrast Down"
        case .softwareContrastUpFine: return "Software Contrast Up (Fine)"
        case .softwareContrastDownFine: return "Software Contrast Down (Fine)"
        case .warmer: return "Warmer"
        case .cooler: return "Cooler"
        case .resetSoftwareAdjustments: return "Reset Software Adjustments"
        case .toggleSoftwareAdjustments: return "Suspend or Resume Software Adjustments"
        case .volumeUp: return "CoreAudio Volume Up"
        case .volumeDown: return "CoreAudio Volume Down"
        case .volumeUpFine: return "CoreAudio Volume Up (Fine)"
        case .volumeDownFine: return "CoreAudio Volume Down (Fine)"
        case .toggleMute: return "Toggle CoreAudio Mute"
        case .mute: return "Mute CoreAudio Output"
        case .unmute: return "Unmute CoreAudio Output"
        }
    }

    /// The binding shipped by default for this action (nil = unbound out of the box).
    public var defaultBinding: KeyBinding? {
        switch self {
        // ⌃⌥⌘R — the always-available Reconnect-All (recovery hierarchy step 3).
        case .reconnectAll: return KeyboardShortcutRegistry.recoveryChord
        case .brightnessDown: return KeyBinding(keyCode: 0x7A, modifiers: KeyBinding.shift) // ⇧F1
        case .brightnessUp: return KeyBinding(keyCode: 0x78, modifiers: KeyBinding.shift) // ⇧F2
        default: return nil
        }
    }
}

/// A global hotkey combo: a Carbon virtual key code plus a Carbon modifier mask. Mirrors the Carbon
/// modifier constants here so the cross-platform core doesn't import Carbon; the macOS layer passes
/// these straight to `RegisterEventHotKey`.
public struct KeyBinding: Hashable, Sendable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let command: UInt32 = 0x0100   // cmdKey
    public static let shift: UInt32 = 0x0200      // shiftKey
    public static let option: UInt32 = 0x0800     // optionKey
    public static let control: UInt32 = 0x1000    // controlKey
    public static let controlOptionCommand: UInt32 = control | option | command
}

/// One "jump to input" hotkey binding (Lunar-parity todo 4, "Input Hotkeys") — a chord bound to
/// switching one specific display to one specific DDC input code, e.g. "⌃⌥⌘1 → Desk monitor, HDMI 2".
/// Kept apart from `HotkeyAction` because its target is user-configured data (a persistent display
/// identity plus an input code) rather than a fixed system action, so the registry holds any number
/// of these instead of the one-slot-per-action model `bindings` uses.
public struct InputSwitchBinding: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    /// The target display's persistent identity (EDID/UUID-derived `DisplayRecordID`, never a
    /// transient port/CG id), so the binding still finds the right panel after a reconnect or a
    /// dock re-plug that reorders ports.
    public var displayID: DisplayRecordID
    /// The DDC/CI input-source code (VCP 0x60) to switch to, e.g. 0x11 for HDMI 1.
    public var inputCode: Int
    public var binding: KeyBinding

    public init(id: String = UUID().uuidString, displayID: DisplayRecordID, inputCode: Int, binding: KeyBinding) {
        self.id = id
        self.displayID = displayID
        self.inputCode = inputCode
        self.binding = binding
    }
}

/// The user's global-shortcut bindings — a map from action to combo, plus any number of input-switch
/// bindings — with conflict detection and a merge-over-defaults. Pure value type (exercised by
/// `make test`); the macOS layer registers the resulting bindings via Carbon.
public struct KeyboardShortcutRegistry: Hashable, Sendable, Codable {
    public private(set) var bindings: [HotkeyAction: KeyBinding]
    /// Configured input-switch hotkeys (todo 4). Unlike `bindings`, there is no shipped default and
    /// no upper bound on how many can coexist.
    public private(set) var inputSwitchBindings: [InputSwitchBinding]
    /// Actions the user explicitly left without a shortcut (SO-01). A missing `bindings` entry means
    /// "use the default", so clearing a shipped shortcut needs its own record: without it the merge
    /// over defaults put the default straight back on the next registration or reload.
    public private(set) var disabledActions: Set<HotkeyAction>

    public init(bindings: [HotkeyAction: KeyBinding] = [:], inputSwitchBindings: [InputSwitchBinding] = [],
                disabledActions: Set<HotkeyAction> = []) {
        self.bindings = bindings
        self.inputSwitchBindings = inputSwitchBindings
        self.disabledActions = disabledActions
    }

    /// The shipped defaults (Reconnect-All and Shift-F1/F2 brightness).
    public static var defaults: KeyboardShortcutRegistry {
        var b: [HotkeyAction: KeyBinding] = [:]
        for action in HotkeyAction.allCases { if let d = action.defaultBinding { b[action] = d } }
        return KeyboardShortcutRegistry(bindings: b)
    }

    public func binding(for action: HotkeyAction) -> KeyBinding? { bindings[action] }

    /// Sets the binding for an action, or — with nil — leaves it explicitly unbound, which survives
    /// merging over the defaults. Going back to the shipped shortcut is `restoreDefault(for:)`.
    public mutating func setBinding(_ binding: KeyBinding?, for action: HotkeyAction) {
        bindings[action] = binding
        if binding == nil { disabledActions.insert(action) } else { disabledActions.remove(action) }
    }

    /// Drops the user's choice for one action (custom chord or explicit "none"), so the shipped
    /// default — or no shortcut, for actions without one — applies again.
    public mutating func restoreDefault(for action: HotkeyAction) {
        bindings[action] = nil
        disabledActions.remove(action)
    }

    /// Every fixed action back on its shipped shortcut. Input-switch bindings are the user's own
    /// data with no defaults to return to, so they are kept.
    public func restoringDefaults() -> KeyboardShortcutRegistry {
        KeyboardShortcutRegistry(bindings: Self.defaults.bindings, inputSwitchBindings: inputSwitchBindings)
    }

    /// The action bound to a combo, if any (deterministic by action order).
    public func action(for binding: KeyBinding) -> HotkeyAction? {
        HotkeyAction.allCases.first { bindings[$0] == binding }
    }

    /// True if `binding` is already used by an action other than `excluding`.
    public func conflicts(_ binding: KeyBinding, excluding action: HotkeyAction? = nil) -> Bool {
        HotkeyAction.allCases.contains { $0 != action && bindings[$0] == binding }
    }

    /// Combos assigned to more than one action.
    public func conflictingBindings() -> [KeyBinding: [HotkeyAction]] {
        var byBinding: [KeyBinding: [HotkeyAction]] = [:]
        for action in HotkeyAction.allCases where bindings[action] != nil {
            byBinding[bindings[action]!, default: []].append(action)
        }
        return byBinding.filter { $0.value.count > 1 }
    }

    /// Adds a new input-switch binding, or replaces the existing one sharing its id.
    public mutating func addInputSwitchBinding(_ entry: InputSwitchBinding) {
        inputSwitchBindings.removeAll { $0.id == entry.id }
        inputSwitchBindings.append(entry)
    }

    /// Removes the input-switch binding with `id`, if any.
    public mutating func removeInputSwitchBinding(id: String) {
        inputSwitchBindings.removeAll { $0.id == id }
    }

    /// True if `combo` is already claimed by a fixed action or by another input-switch binding.
    /// `excludingInputSwitchID` lets an edit-in-place check exclude the entry being edited (pass nil
    /// when checking a brand-new binding).
    public func inputSwitchBindingConflicts(_ combo: KeyBinding, excludingInputSwitchID: String?) -> Bool {
        conflicts(combo) || inputSwitchBindings.contains {
            $0.id != excludingInputSwitchID && $0.binding == combo
        }
    }

    /// This registry layered over the defaults: persisted bindings win, defaults fill the gaps, and
    /// an action the user explicitly cleared stays unbound. A default whose chord a persisted binding
    /// (an action's or an input hotkey's) already uses is skipped: a shortcut shipped by a later
    /// release must not take a chord the user chose before it existed — registration gives a chord
    /// to the earliest action, so the default would win and the user's own binding would go dead.
    /// The skipped action is left unbound but not cleared, and the registration plan reports it as
    /// a conflict with the slot holding its chord. There is no default input-switch binding, so
    /// those pass through unchanged.
    public func mergedWithDefaults() -> KeyboardShortcutRegistry {
        var merged = KeyboardShortcutRegistry(inputSwitchBindings: inputSwitchBindings, disabledActions: disabledActions)
        for (action, binding) in bindings where !disabledActions.contains(action) { merged.bindings[action] = binding }
        var savedChords = Set(merged.bindings.values)
        savedChords.formUnion(inputSwitchBindings.map(\.binding))
        for action in HotkeyAction.allCases where merged.bindings[action] == nil && !disabledActions.contains(action) {
            // The recovery chord is the exception: it is reserved for Reconnect All (owner decision
            // #26), so a saved binding of another action on it never takes it away — the
            // registration plan reports that binding as the conflict instead.
            if let shipped = action.defaultBinding, action == .reconnectAll || !savedChords.contains(shipped) {
                merged.bindings[action] = shipped
            }
        }
        return merged
    }

    /// What registration actually works from: the merge over the defaults, with the older
    /// Reconnect-All on/off switch (`OpenDisplaySettings.reconnectAllHotkeyEnabled`) folded in as an
    /// explicit "no shortcut". Settings shows, conflict-checks and registers this one registry, so
    /// the three can't disagree.
    public func effective(reconnectAllEnabled: Bool) -> KeyboardShortcutRegistry {
        // Folded in before the merge, so a Reconnect-All chord the switch turns off doesn't keep
        // another action's default out (see `mergedWithDefaults`).
        var source = self
        if !reconnectAllEnabled { source.setBinding(nil, for: .reconnectAll) }
        return source.mergedWithDefaults()
    }

    /// ⌃⌥⌘R, Reconnect All's shipped chord. Reserved for it while the recovery shortcut is on
    /// (owner decision #26): the one way back when the screens are unusable must not be given to
    /// anything else.
    public static let recoveryChord = KeyBinding(keyCode: 0x0F, modifiers: KeyBinding.controlOptionCommand)

    /// Whether this registry keeps the recovery chord for Reconnect All: unless the user left Reconnect
    /// All without a shortcut. Call it on `effective(reconnectAllEnabled:)`, which folds the older
    /// on/off switch in as exactly that.
    public var reservesRecoveryChord: Bool {
        !disabledActions.contains(.reconnectAll)
    }

    /// True when `binding` is the recovery chord, `slot` isn't Reconnect All and the chord is
    /// reserved — the recorder refuses such a binding outright rather than saving a conflict.
    public func isReservedForRecovery(_ binding: KeyBinding, slot: HotkeySlot) -> Bool {
        reservesRecoveryChord && binding == Self.recoveryChord && slot != .action(.reconnectAll)
    }

    /// The slot already using `binding` — a fixed action or an input-switch hotkey — other than
    /// `excluding`, or nil when the chord is free. Fixed actions are checked first, in list order, so
    /// the answer is deterministic. Call it on `effective(reconnectAllEnabled:)`: a raw persisted
    /// registry lacks the defaults and would call a shipped chord free.
    public func slot(using binding: KeyBinding, excluding: HotkeySlot? = nil) -> HotkeySlot? {
        for action in HotkeyAction.allCases where bindings[action] == binding {
            let slot = HotkeySlot.action(action)
            if slot != excluding { return slot }
        }
        for entry in inputSwitchBindings where entry.binding == binding {
            let slot = HotkeySlot.inputSwitch(id: entry.id)
            if slot != excluding { return slot }
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case bindings
        case inputSwitchBindings
        case disabledActions
    }

    /// Decodes tolerantly across two shapes: the current `{bindings: {...}, inputSwitchBindings: [...]}`
    /// object, and the pre-todo-4 legacy shape where the WHOLE payload was the flat
    /// `{actionRawValue: KeyBinding}` map (no wrapper, no input-switch bindings). An action key a
    /// future/older build doesn't recognise is ignored rather than failing the whole load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rawBindings = try container.decodeIfPresent([String: KeyBinding].self, forKey: .bindings) {
            bindings = Self.decodeBindings(rawBindings)
            inputSwitchBindings = try container.decodeIfPresent([InputSwitchBinding].self, forKey: .inputSwitchBindings) ?? []
            // Files from before the disabled state existed simply have none; an action name this
            // build doesn't know is dropped like an unknown binding key.
            let rawDisabled = (try? container.decodeIfPresent([String].self, forKey: .disabledActions)) ?? nil
            disabledActions = Set((rawDisabled ?? []).compactMap(HotkeyAction.init(rawValue:)))
            return
        }
        let legacyRawBindings = try decoder.singleValueContainer().decode([String: KeyBinding].self)
        bindings = Self.decodeBindings(legacyRawBindings)
        inputSwitchBindings = []
        disabledActions = []
    }

    private static func decodeBindings(_ raw: [String: KeyBinding]) -> [HotkeyAction: KeyBinding] {
        var bindings: [HotkeyAction: KeyBinding] = [:]
        for (key, binding) in raw { if let action = HotkeyAction(rawValue: key) { bindings[action] = binding } }
        return bindings
    }

    public func encode(to encoder: Encoder) throws {
        var rawBindings: [String: KeyBinding] = [:]
        for (action, binding) in bindings { rawBindings[action.rawValue] = binding }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawBindings, forKey: .bindings)
        try container.encode(inputSwitchBindings, forKey: .inputSwitchBindings)
        try container.encode(disabledActions.map(\.rawValue).sorted(), forKey: .disabledActions)
    }
}
