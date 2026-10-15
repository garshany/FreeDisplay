import Foundation

/// Whether one CoreAudio control exists on an output and whether OpenDisplay may write it (TR-16).
/// Volume and mute are reported separately: an output can have either without the other, and a
/// control that exists but isn't settable must not be offered as one.
public enum AudioControlAccess: String, Hashable, Sendable {
    case absent
    case readOnly
    case settable

    public var isSettable: Bool { self == .settable }
}

/// One macOS sound output as CoreAudio reports it (TR-16/T29). `uid` is CoreAudio's persistent
/// device identifier (`kAudioDevicePropertyDeviceUID`) and the only property that names one device
/// for certain; `name` is what Sound settings shows and can repeat across identical monitors. Plain
/// values, so the core needn't import CoreAudio.
public struct AudioOutputDevice: Hashable, Sendable, Identifiable {
    public var uid: String
    public var name: String
    public var transport: AudioOutputTransport
    public var volume: AudioControlAccess
    public var mute: AudioControlAccess
    /// The output's current volume (0...1) when it could be read.
    public var volumeLevel: Float?
    /// The output's current mute state when it could be read.
    public var isMuted: Bool?

    public var id: String { uid }

    public init(uid: String, name: String, transport: AudioOutputTransport,
                volume: AudioControlAccess = .absent, mute: AudioControlAccess = .absent,
                volumeLevel: Float? = nil, isMuted: Bool? = nil) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.volume = volume
        self.mute = mute
        self.volumeLevel = volumeLevel
        self.isMuted = isMuted
    }

    /// Volume can be stepped: settable, and its current level is known — a step is computed from
    /// what the output reports, never from an assumed level.
    public var volumeIsAdjustable: Bool { volume.isSettable && volumeLevel.map { $0.isFinite && (0...1).contains($0) } == true }

    /// Mute can be toggled: settable, and its current state is known.
    public var muteIsToggleable: Bool { mute.isSettable && isMuted != nil }
}

/// What a user-entered output name or UID refers to among the outputs present now.
public enum AudioDeviceResolution: Hashable, Sendable {
    /// Nothing entered.
    case unset
    /// Exactly one present output.
    case matched(AudioOutputDevice)
    /// Several present outputs fit; none is chosen. Entering the UID disambiguates.
    case ambiguous([AudioOutputDevice])
    /// Something was entered and no present output fits it.
    case missing

    public var device: AudioOutputDevice? {
        if case .matched(let device) = self { return device }
        return nil
    }

    public var isUnset: Bool { self == .unset }
}

/// Resolves the text a user typed for a display's audio output (SD-16/TB-08). FreeDisplay rejects
/// what the guide documents as hazards: an empty field never matches the first output, and a name
/// that fits several outputs selects none of them, so identical monitors need their UID.
public enum AudioDeviceSelector {
    /// How loosely text may match.
    public enum Strictness: Hashable, Sendable {
        /// The whole UID or the whole name. Used where the match is written to (native association).
        case exact
        /// Also a fragment of the name or UID — only when a single present output contains it.
        /// Used for keyboard matching, which only decides whether a key is taken.
        case allowsFragment
    }

    /// Case-insensitive, surrounding whitespace dropped and inner runs of whitespace collapsed.
    /// Digits and punctuation are kept: model numbers are what tells two monitors apart.
    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// - Returns: `.unset` for blank text; otherwise the single present output it names, in this
    ///   order: exact UID, exact name, then (when allowed) a fragment of the name or UID.
    public static func resolve(_ selector: String?, in devices: [AudioOutputDevice],
                               strictness: Strictness) -> AudioDeviceResolution {
        let raw = (selector ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .unset }

        // A UID is CoreAudio's identity: matched as typed first, then ignoring case.
        if let result = single(devices.filter { $0.uid == raw }) { return result }
        if let result = single(devices.filter { $0.uid.lowercased() == raw.lowercased() }) { return result }

        let needle = normalize(raw)
        if let result = single(devices.filter { normalize($0.name) == needle }) { return result }

        if strictness == .allowsFragment {
            let fragment = devices.filter {
                normalize($0.name).contains(needle) || $0.uid.lowercased().contains(needle)
            }
            if let result = single(fragment) { return result }
        }
        return .missing
    }

    /// One device → matched, several → ambiguous, none → keep looking (nil).
    private static func single(_ found: [AudioOutputDevice]) -> AudioDeviceResolution? {
        switch found.count {
        case 0: return nil
        case 1: return .matched(found[0])
        default: return .ambiguous(found)
        }
    }
}

/// One native volume or mute step on a CoreAudio output (SD-16): the level that is written, and the
/// mute state that goes with it — raising an output above its minimum unmutes it, reaching the
/// minimum mutes it, as macOS's own keys do. Mute is only touched when it can be written.
public enum NativeVolumeStep {
    public struct Result: Hashable, Sendable {
        public var level: Float
        /// The mute state to write; nil leaves mute alone.
        public var mute: Bool?
    }

    /// - Returns: nil when the output's volume can't be stepped (not settable, or level unknown).
    public static func step(_ device: AudioOutputDevice, delta: Float) -> Result? {
        guard delta.isFinite, device.volumeIsAdjustable, let current = device.volumeLevel else { return nil }
        let level = min(1, max(0, current + delta))
        var mute: Bool?
        if device.muteIsToggleable, let muted = device.isMuted {
            if level > 0, muted, delta > 0 { mute = false }
            if level <= 0, !muted { mute = true }
        }
        return Result(level: level, mute: mute)
    }

    /// The mute state a toggle writes, or nil when mute can't be toggled.
    public static func toggledMute(_ device: AudioOutputDevice) -> Bool? {
        guard device.muteIsToggleable, let muted = device.isMuted else { return nil }
        return !muted
    }
}
