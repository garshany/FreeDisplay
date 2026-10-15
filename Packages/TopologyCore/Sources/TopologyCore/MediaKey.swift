import DisplayDomain
import Foundation

/// What a hardware media key does (Batch-3 #1). Distinct from `HotkeyAction` (configurable Carbon
/// chords): these are the fixed `NX_KEYTYPE_*` keys captured by the macOS event tap, mapped here to a
/// semantic action plus a signed step so the app can drive the right control on the right display.
public enum MediaKeyAction: String, Hashable, Sendable, CaseIterable {
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    case muteToggle

    /// The IOKit `NX_KEYTYPE_*` subtype code → action (`ev_keymap.h`). Unknown codes return nil, so the
    /// tap lets that key pass through to macOS untouched.
    public static func from(nxKeyType code: Int) -> MediaKeyAction? {
        switch code {
        case NXKeyType.soundUp: return .volumeUp
        case NXKeyType.soundDown: return .volumeDown
        case NXKeyType.mute: return .muteToggle
        case NXKeyType.brightnessUp: return .brightnessUp
        case NXKeyType.brightnessDown: return .brightnessDown
        default: return nil
        }
    }

    /// True for the volume/mute keys. Unlike brightness (which follows `MediaKeyTargetMode`), these
    /// follow `AudioKeyEngagement`/`AudioKeyTargetMode` (`AudioKeyRouter`) — by default the display
    /// the current sound output belongs to — and otherwise pass through so macOS adjusts the real
    /// output device (speakers, AirPods, USB DAC) with its own HUD.
    public var isVolume: Bool {
        switch self {
        case .volumeUp, .volumeDown, .muteToggle: return true
        case .brightnessUp, .brightnessDown: return false
        }
    }

    public var isBrightness: Bool { !isVolume }

    public func acceptsModifiers(shiftPressed: Bool, brightnessRequiresShift: Bool) -> Bool {
        !isBrightness || !brightnessRequiresShift || shiftPressed
    }

    /// +1 to raise, -1 to lower, 0 for a non-directional action (mute).
    public var sign: Float {
        switch self {
        case .brightnessUp, .volumeUp: return 1
        case .brightnessDown, .volumeDown: return -1
        case .muteToggle: return 0
        }
    }

    /// The signed level change this key applies. macOS moves brightness/volume in 1/16 steps, and a
    /// quarter-step (1/64) while ⇧⌥ is held — mirror that. Mute returns 0 (the caller toggles state).
    public func signedDelta(fineStep: Bool) -> Float {
        sign * (fineStep ? MediaKeyStep.fine : MediaKeyStep.coarse)
    }

    /// The signed change under the user's adjustment steps (SO-29): `fineStep` (⇧⌥ held) asks for
    /// whichever step isn't the default one. With default steps this equals `signedDelta(fineStep:)`.
    public func signedDelta(fineStep: Bool, steps: AdjustmentSteps) -> Float {
        sign * steps.nativeKeyFraction(modifierRequestsFine: fineStep)
    }
}

/// macOS media-key step sizes (fraction of the 0...1 range).
public enum MediaKeyStep {
    public static let coarse: Float = 1.0 / 16.0
    public static let fine: Float = 1.0 / 64.0
}

/// IOKit `NX_KEYTYPE_*` subtype codes for the media keys we care about (`ev_keymap.h`). Held here as
/// plain constants so the cross-platform core needn't import IOKit; the macOS tap decodes the event
/// subtype and passes the integer in.
public enum NXKeyType {
    public static let soundUp = 0
    public static let soundDown = 1
    public static let brightnessUp = 2
    public static let brightnessDown = 3
    public static let mute = 7
}

/// Which displays the brightness keys act on (persisted in settings, Batch-3 #3/#5, SO-27). Resolved
/// by `BrightnessKeyRouter`; a mode that finds no suitable display changes nothing rather than
/// reaching for an unrelated one.
public enum MediaKeyTargetMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// The display under the pointer, with the displays mirroring with it.
    case underCursor
    /// The display showing the focused window, with the displays mirroring with it.
    case focusedWindow
    /// Every display the keys may change, each adjusted directly (group sync is bypassed so no
    /// display is written twice).
    case allDisplays
    /// Always the current main display.
    case mainDisplay
    /// Always the built-in panel; nothing when it is off or closed.
    case builtInAlways
    /// External under the pointer, otherwise the main or first active external; never the built-in.
    case externalOnly
}
