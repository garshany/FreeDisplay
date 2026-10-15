import Foundation

/// What an on-screen-display HUD should show for a brightness/volume/mute change (Batch-3 #2). Pure
/// value type (exercised by `make test`); the macOS layer renders it in a floating panel.
public struct OSDContent: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case brightness
        case volume
        case mute
        /// A DDC input-source switch (Lunar-parity todo 4). Shown as a text label rather than a
        /// filled-segment bar, since an input has no meaningful 0...1 level.
        case input
    }

    /// How much the shown level is known to be true (TR-17). A level bar animating to a value says
    /// nothing about whether the display took it, so the HUD keeps the difference visible.
    public enum Assurance: String, Hashable, Sendable, Codable {
        /// OpenDisplay itself carries the change (software dimming): what is shown is what is applied.
        case applied
        /// Sent to the display, not read back yet — the normal state of a hardware change.
        case requested
        /// The display reported the value afterwards.
        case verified
        /// The display answered with another value, or didn't answer: the change is not confirmed.
        case notConfirmed
    }

    /// Number of segments in the native-style bar.
    public static let segmentCount = 16

    public var kind: Kind
    /// Normalized level, always clamped to 0...1. Unused (0) for `.input`.
    public var value: Float
    /// The text shown in place of the segment bar for `.input` (e.g. "HDMI 2"); nil for every other
    /// kind.
    public var label: String?
    /// See `Assurance`. Defaults to `.requested`: a caller that can't say otherwise claims nothing.
    public var assurance: Assurance

    public init(kind: Kind, value: Float, label: String? = nil, assurance: Assurance = .requested) {
        self.kind = kind
        self.value = max(0, min(1, value))
        self.label = label
        self.assurance = assurance
    }

    /// Filled segments (0...16) for the bar, rounded to the nearest segment.
    public var filledSegments: Int {
        let n = Int((value * Float(Self.segmentCount)).rounded())
        return max(0, min(Self.segmentCount, n))
    }

    /// Whole-percent level for an optional numeric readout.
    public var percent: Int { Int((value * 100).rounded()) }

    /// SF Symbol glyph for this content. A style may swap it, but this is the native-looking default.
    public var glyph: String {
        switch kind {
        case .brightness: return "sun.max"
        case .mute: return "speaker.slash"
        case .volume:
            if value <= 0 { return "speaker.slash" }
            return value < 0.5 ? "speaker.wave.1" : "speaker.wave.2"
        case .input: return "arrow.triangle.swap"
        }
    }
}
