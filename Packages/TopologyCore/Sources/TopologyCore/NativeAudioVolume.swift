/// Public CoreAudio volume properties can be on the main element or individual output channels.
/// The glue supplies the main element alone when available, otherwise the device's channel controls.
public enum NativeAudioVolume {
    public struct Channel: Hashable, Sendable {
        public var element: UInt32
        public var access: AudioControlAccess
        public var level: Float?

        public init(element: UInt32, access: AudioControlAccess, level: Float?) {
            self.element = element
            self.access = access
            self.level = level
        }
    }

    public static func access(_ channels: [Channel]) -> AudioControlAccess {
        guard !channels.isEmpty else { return .absent }
        return channels.allSatisfy { $0.access.isSettable } ? .settable : .readOnly
    }

    public static func level(_ channels: [Channel]) -> Float? {
        guard !channels.isEmpty, channels.allSatisfy({
            $0.level.map { $0.isFinite && (0...1).contains($0) } == true
        }) else { return nil }
        return channels.compactMap(\.level).max()
    }

    /// Scale all channels by the same ratio so volume keys do not reset stereo/surround balance.
    /// At silence there is no ratio to preserve; an explicit nonzero request raises channels equally.
    public static func writes(level requested: Float, channels: [Channel]) -> [Channel]? {
        guard requested.isFinite, access(channels) == .settable, let current = level(channels) else { return nil }
        let requested = min(1, max(0, requested))
        return channels.map { channel in
            var result = channel
            result.level = current > 0 ? ((channel.level ?? 0) / current) * requested : requested
            return result
        }
    }
}

/// A native multi-channel write can fail after some channels changed. Reporting this separately
/// prevents a second macOS key adjustment while still surfacing the failure to the user.
public enum NativeAudioWriteResult: Equatable, Sendable {
    case rejected
    case accepted
    case partial

    public var wasApplied: Bool { self != .rejected }
}
