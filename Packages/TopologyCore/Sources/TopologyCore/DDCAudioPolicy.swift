import Foundation

/// Volume-key eligibility and mute decisions for a monitor's DDC audio (TB-02 / TB-03). Pure.
///
/// Why this exists: the media-key tap SWALLOWS a key it handles, so consuming a volume key for a
/// monitor whose DDC volume doesn't actually work leaves the user with no volume control at all —
/// macOS never sees the key. Eligibility therefore needs evidence (a successful read of the volume
/// control), not the fail-open "capabilities not read yet, so assume yes" used for showing controls.
/// Mute likewise must not pretend: a monitor's discrete mute (VCP 0x8D) is used only when it was
/// read back; otherwise mute is emulated with volume 0 and labelled as such, and unmute restores
/// only a level the user actually had — never an invented default.
public enum DDCAudioPolicy {
    /// What the app knows about one display's DDC audio.
    public struct Capability: Equatable, Sendable {
        /// The volume level (0...1) the monitor reported (kept current by later verified writes);
        /// nil = never successfully read.
        public var volume: Float?
        /// The capabilities string lists VCP 0x62 — or hasn't been read. It can only remove a
        /// control; it never proves one works.
        public var volumeAdvertised: Bool
        /// The last volume write failed at the transport and nothing has re-confirmed the control.
        public var volumeWriteFailed: Bool
        /// The monitor's discrete mute (VCP 0x8D) as read back: true = muted. Nil = not readable.
        public var discreteMuted: Bool?
        /// The last discrete-mute write failed at the transport.
        public var muteWriteFailed: Bool

        public init(volume: Float?, volumeAdvertised: Bool = true, volumeWriteFailed: Bool = false,
                    discreteMuted: Bool? = nil, muteWriteFailed: Bool = false) {
            self.volume = volume
            self.volumeAdvertised = volumeAdvertised
            self.volumeWriteFailed = volumeWriteFailed
            self.discreteMuted = discreteMuted
            self.muteWriteFailed = muteWriteFailed
        }
    }

    /// Whether volume up/down keys may be consumed for this display. Anything short of a confirmed,
    /// currently working DDC volume leaves the key to macOS.
    public static func volumeKeysUsable(_ capability: Capability) -> Bool {
        capability.volume != nil && capability.volumeAdvertised && !capability.volumeWriteFailed
    }

    /// How a mute toggle would be carried out.
    public enum MuteAction: Equatable, Sendable {
        /// Write the monitor's own mute (VCP 0x8D): `mute` true sends 1 (mute), false sends 2 (unmute).
        case discrete(mute: Bool)
        /// No discrete mute: set the volume to 0, remembering `remember` for the unmute.
        case zeroVolume(remember: Float)
        /// Undo a zero-volume mute: restore the remembered level, then forget it.
        case restore(level: Float)
        /// Nothing truthful to do — no working audio control, or the volume is already 0 with no
        /// remembered level (an unmute would have to invent one).
        case unavailable
    }

    /// - Parameter remembered: the level saved by the last zero-volume mute, if any.
    public static func muteAction(_ capability: Capability, remembered: Float?) -> MuteAction {
        if let muted = capability.discreteMuted, !capability.muteWriteFailed { return .discrete(mute: !muted) }
        guard volumeKeysUsable(capability), let volume = capability.volume else { return .unavailable }
        if volume > 0 { return .zeroVolume(remember: volume) }
        if let remembered, remembered > 0 { return .restore(level: remembered) }
        return .unavailable
    }

    /// Whether the mute key may be consumed for this display.
    public static func muteKeyUsable(_ capability: Capability, remembered: Float?) -> Bool {
        muteAction(capability, remembered: remembered) != .unavailable
    }

    /// Reads a discrete-mute reply (MCCS VCP 0x8D: 1 = muted, 2 = unmuted). Any other value is not
    /// a usable mute state and yields nil.
    public static func discreteMuteState(fromVCPValue value: Int) -> Bool? {
        switch value {
        case 1: return true
        case 2: return false
        default: return nil
        }
    }

    /// The VCP 0x8D value that requests `mute`.
    public static func discreteMuteValue(mute: Bool) -> Int { mute ? 1 : 2 }
}
