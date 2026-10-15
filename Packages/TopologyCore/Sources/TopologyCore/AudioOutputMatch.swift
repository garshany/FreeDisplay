import DisplayDomain
import Foundation

/// The physical route a CoreAudio output device sits on. Only `hdmi`/`displayPort` can be a monitor's
/// own audio as far as automatic matching goes; built-in speakers, USB DACs, Bluetooth/AirPods and
/// aggregate/multi-output devices reach a display only through an explicit per-display binding
/// (TR-16/FA-26). Held as plain values so the cross-platform core needn't import CoreAudio — the macOS
/// glue maps `kAudioDeviceTransportType*` onto this (mirrors how `NXKeyType` keeps IOKit constants out
/// of the core).
public enum AudioOutputTransport: String, Hashable, Sendable {
    case hdmi
    case displayPort
    case builtIn
    case usb
    case bluetooth
    /// An aggregate or multi-output device the user built in Audio MIDI Setup.
    case aggregate
    case virtual
    case airPlay
    case other

    /// Whether automatic (unconfigured) matching may take this output for a display's own audio.
    public var mayBeDisplayAudio: Bool { self == .hdmi || self == .displayPort }
}

/// Resolves which display, if any, carries the system's default audio output (Batch-3, media-key fix).
/// Pure: given the default output device's name + transport and the current displays (with their
/// user-facing names), it returns the record of the external display the audio is coming through — or
/// nil when the route isn't a display or can't be matched confidently. The volume media keys follow
/// this so they drive the DDC volume of whatever the *sound* is actually playing on, not whatever
/// display the brightness target mode happens to pick.
public enum AudioOutputDisplayMatcher {
    /// - Parameters:
    ///   - deviceName: the default output device's CoreAudio name (e.g. the monitor's product name).
    ///   - transport: the device's transport; anything but `hdmi`/`displayPort` yields nil (pass through).
    ///   - displays: the current observations.
    ///   - names: user-facing name per display (from the app's `displayName(for:)` resolution).
    /// - Returns: the display the audio routes through, or nil to fail safe (never guess).
    public static func match(
        deviceName: String,
        transport: AudioOutputTransport,
        displays: [DisplayObservation],
        names: [DisplayRecordID: String]
    ) -> DisplayRecordID? {
        // Only monitor audio (HDMI / DisplayPort) can belong to a display. Speakers, USB, AirPods,
        // aggregate devices, etc. are never a display → pass through so macOS adjusts them natively.
        guard transport.mayBeDisplayAudio else { return nil }

        // Audio can only be coming through an active, non-built-in panel.
        let candidates = displays.filter { $0.isActive && $0.displayClass != .builtIn }
        guard !candidates.isEmpty else { return nil }

        let needle = normalize(deviceName)
        if !needle.isEmpty {
            // Exact name match — but only when a single display carries that name. Identical monitors
            // share a product name, so two exact hits are ambiguous (CoreAudio routes to just one of
            // them and we can't tell which) → don't guess.
            let exact = candidates.filter { normalize(names[$0.recordID] ?? "") == needle }
            if exact.count == 1 { return exact[0].recordID }
            if exact.count > 1 { return nil }
            // Then prefix/contains either way — monitor audio device names usually equal or contain the
            // display's product name (and vice versa). One unambiguous hit only; two → don't guess.
            let contained = candidates.filter { candidate in
                let hay = normalize(names[candidate.recordID] ?? "")
                guard !hay.isEmpty else { return false }
                return hay.contains(needle) || needle.contains(hay)
            }
            if contained.count == 1 { return contained[0].recordID }
            if contained.count > 1 { return nil }
        }

        // A sole external is not identity evidence (an HDMI receiver may be unrelated). The user
        // can explicitly bind its output UID instead of having a key silently choose a monitor.
        return nil
    }

    private static func normalize(_ string: String) -> String {
        AudioDeviceSelector.normalize(string)
    }
}
