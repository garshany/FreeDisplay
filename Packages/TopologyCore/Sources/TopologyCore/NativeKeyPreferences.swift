import Foundation

/// When the brightness keys are taken from macOS (SO-25).
public enum BrightnessKeyTakeover: String, Hashable, Sendable, Codable, CaseIterable {
    /// Whenever a display the keys would change can be controlled by OpenDisplay.
    case anyControllableDisplay
    /// Only when a display the keys would change is one macOS's own brightness keys can't adjust;
    /// otherwise macOS keeps the keys (and its own targeting and steps).
    case onlyWhenMacOSCannot
}

/// When the volume and mute keys are taken from macOS (SO-25/TA-06). Engagement only decides whether
/// OpenDisplay handles a key at all; which displays it then changes is `AudioKeyTargetMode`.
public enum AudioKeyEngagement: String, Hashable, Sendable, Codable, CaseIterable {
    /// The current sound output belongs to a display OpenDisplay can control.
    case outputMatchesDisplay
    /// The current sound output has no volume macOS can set, and a controllable display exists.
    case outputLacksVolumeControl
    /// Any display with controllable audio is connected.
    case anyControllableDisplay
    /// Always — a key still needs a display or the native fallback to act on.
    case always
}

/// Which displays the volume and mute keys change once engaged (SO-27/SO-28).
public enum AudioKeyTargetMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// The displays the current sound output belongs to.
    case matchingOutput
    /// The display under the pointer and the displays mirroring with it.
    case underCursor
    /// The display with the focused window and the displays mirroring with it.
    case focusedWindow
    /// Every display with controllable audio.
    case allDisplays
}

/// Whether a volume key plays the feedback sound when it's released (FA-20).
public enum VolumeFeedbackSound: String, Hashable, Sendable, Codable, CaseIterable {
    /// macOS's "Play feedback when volume is changed" — read best-effort; unknown counts as off.
    case followSystem
    case always
    case never
}

/// The native-keyboard policies beyond the original on/off, target and Shift settings (SO-25,
/// SO-26, SO-27, SO-28, FA-19, FA-20, TA-06). Kept together so files written before they existed
/// decode to these defaults, and each field degrades alone when unreadable.
public struct NativeKeyPreferences: Hashable, Sendable, Codable {
    /// The brightness keys (and F14/F15 when mapped) are captured. Turning it off returns only
    /// those keys to macOS.
    public var brightnessKeysEnabled: Bool
    /// The volume and mute keys are captured. Turning it off returns only those keys to macOS.
    public var volumeKeysEnabled: Bool
    public var brightnessTakeover: BrightnessKeyTakeover
    /// F14 lowers and F15 raises brightness (Scroll Lock / Pause on many PC keyboards). A bare key a
    /// global shortcut already uses keeps going to that shortcut.
    public var alternativeBrightnessKeys: Bool
    public var audioEngagement: AudioKeyEngagement
    public var audioTarget: AudioKeyTargetMode
    /// A volume or mute key no display can act on adjusts the current sound output through macOS's
    /// audio interface instead, when that output allows it; otherwise the key goes to macOS.
    public var nativeAudioFallback: Bool
    /// The mute key always goes to macOS; the volume keys stay captured.
    public var muteKeyLeftToMacOS: Bool
    public var volumeFeedbackSound: VolumeFeedbackSound
    /// Nil preserves the shared step preference from files predating independent native policies.
    public var brightnessFineByDefault: Bool?
    public var volumeFineByDefault: Bool?

    public func stepFraction(for action: MediaKeyAction, modifierRequestsFine: Bool, steps: AdjustmentSteps) -> Float {
        var effective = steps
        effective.fineByDefault = (action.isBrightness ? brightnessFineByDefault : volumeFineByDefault)
            ?? steps.fineByDefault
        return effective.nativeKeyFraction(modifierRequestsFine: modifierRequestsFine)
    }

    public init(brightnessKeysEnabled: Bool = true, volumeKeysEnabled: Bool = true,
                brightnessTakeover: BrightnessKeyTakeover = .anyControllableDisplay,
                alternativeBrightnessKeys: Bool = true,
                audioEngagement: AudioKeyEngagement = .outputMatchesDisplay,
                audioTarget: AudioKeyTargetMode = .matchingOutput,
                nativeAudioFallback: Bool = true, muteKeyLeftToMacOS: Bool = false,
                volumeFeedbackSound: VolumeFeedbackSound = .followSystem,
                brightnessFineByDefault: Bool? = nil, volumeFineByDefault: Bool? = nil) {
        self.brightnessKeysEnabled = brightnessKeysEnabled
        self.volumeKeysEnabled = volumeKeysEnabled
        self.brightnessTakeover = brightnessTakeover
        self.alternativeBrightnessKeys = alternativeBrightnessKeys
        self.audioEngagement = audioEngagement
        self.audioTarget = audioTarget
        self.nativeAudioFallback = nativeAudioFallback
        self.muteKeyLeftToMacOS = muteKeyLeftToMacOS
        self.volumeFeedbackSound = volumeFeedbackSound
        self.brightnessFineByDefault = brightnessFineByDefault
        self.volumeFineByDefault = volumeFineByDefault
    }

    public static let `default` = NativeKeyPreferences()

    private enum CodingKeys: String, CodingKey {
        case brightnessKeysEnabled, volumeKeysEnabled, brightnessTakeover, alternativeBrightnessKeys
        case audioEngagement, audioTarget, nativeAudioFallback, muteKeyLeftToMacOS, volumeFeedbackSound
        case brightnessFineByDefault, volumeFineByDefault
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        brightnessKeysEnabled = container.lenient(Bool.self, forKey: .brightnessKeysEnabled)
            ?? defaults.brightnessKeysEnabled
        volumeKeysEnabled = container.lenient(Bool.self, forKey: .volumeKeysEnabled) ?? defaults.volumeKeysEnabled
        brightnessTakeover = container.lenient(BrightnessKeyTakeover.self, forKey: .brightnessTakeover)
            ?? defaults.brightnessTakeover
        alternativeBrightnessKeys = container.lenient(Bool.self, forKey: .alternativeBrightnessKeys)
            ?? defaults.alternativeBrightnessKeys
        audioEngagement = container.lenient(AudioKeyEngagement.self, forKey: .audioEngagement)
            ?? defaults.audioEngagement
        audioTarget = container.lenient(AudioKeyTargetMode.self, forKey: .audioTarget) ?? defaults.audioTarget
        nativeAudioFallback = container.lenient(Bool.self, forKey: .nativeAudioFallback)
            ?? defaults.nativeAudioFallback
        muteKeyLeftToMacOS = container.lenient(Bool.self, forKey: .muteKeyLeftToMacOS)
            ?? defaults.muteKeyLeftToMacOS
        volumeFeedbackSound = container.lenient(VolumeFeedbackSound.self, forKey: .volumeFeedbackSound)
            ?? defaults.volumeFeedbackSound
        brightnessFineByDefault = container.lenient(Bool.self, forKey: .brightnessFineByDefault)
        volumeFineByDefault = container.lenient(Bool.self, forKey: .volumeFineByDefault)
    }
}

/// One display's keyboard and audio preferences (SD-11 keyboard participation, SD-16/TB-08 audio
/// binding), keyed by the display's record id like every other per-display preference. Independent
/// of menu visibility: a display hidden from the menu still receives keys unless excluded here.
public struct DisplayKeyboardAudioPreferences: Hashable, Sendable, Codable {
    /// The brightness and volume keys may change this display. Explicit shortcuts, sliders and
    /// automation are unaffected.
    public var keyboardControl: Bool
    /// The volume keys treat this display as the current output when that output's name or UID is
    /// this text (a fragment that fits a single present output also works). Blank: automatic
    /// matching by the display's product name.
    public var audioMatch: String?
    /// The display's volume and mute go to a macOS sound output instead of the monitor's own audio.
    /// Never changes which output macOS plays through.
    public var nativeAudioEnabled: Bool
    /// That output's exact name or UID. Kept while `nativeAudioEnabled` is off.
    public var nativeAudioDevice: String?
    /// Volume-key changes on this display show OpenDisplay's HUD (when the HUD itself is on).
    public var showsVolumeOSD: Bool

    public init(keyboardControl: Bool = true, audioMatch: String? = nil, nativeAudioEnabled: Bool = false,
                nativeAudioDevice: String? = nil, showsVolumeOSD: Bool = true) {
        self.keyboardControl = keyboardControl
        self.audioMatch = audioMatch
        self.nativeAudioEnabled = nativeAudioEnabled
        self.nativeAudioDevice = nativeAudioDevice
        self.showsVolumeOSD = showsVolumeOSD
    }

    public static let `default` = DisplayKeyboardAudioPreferences()

    /// Nothing differs from a display that was never configured, so nothing needs storing.
    public var isDefault: Bool { normalized == .default }

    /// Blank text stored as nil, so "cleared" and "never set" are one state.
    public var normalized: DisplayKeyboardAudioPreferences {
        var copy = self
        copy.audioMatch = Self.blankAsNil(audioMatch)
        copy.nativeAudioDevice = Self.blankAsNil(nativeAudioDevice)
        return copy
    }

    private static func blankAsNil(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private enum CodingKeys: String, CodingKey {
        case keyboardControl, audioMatch, nativeAudioEnabled, nativeAudioDevice, showsVolumeOSD
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyboardControl = container.lenient(Bool.self, forKey: .keyboardControl) ?? true
        audioMatch = container.lenient(String.self, forKey: .audioMatch)
        nativeAudioEnabled = container.lenient(Bool.self, forKey: .nativeAudioEnabled) ?? false
        nativeAudioDevice = container.lenient(String.self, forKey: .nativeAudioDevice)
        showsVolumeOSD = container.lenient(Bool.self, forKey: .showsVolumeOSD) ?? true
    }
}
