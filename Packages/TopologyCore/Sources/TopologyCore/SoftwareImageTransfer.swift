import Foundation

/// Software contrast (TR-14/IN-17/AM-18): a per-display tone curve around mid-grey, expressed in the
/// SAME colour table as the dim, warmth and XDR boost (`SoftwareImageTransfer`). It changes the
/// picture, not the monitor: hardware contrast is DDC VCP 0x12, on its own scale, and neither one
/// measures the panel's contrast ratio.
///
/// The value is a factor around mid-grey — `neutral` leaves the picture untouched, lower values pull
/// black and white toward grey, higher values push tones apart and clip the ends. ::
///
///     apply(0.25, factor: 1.0) == 0.25    // neutral is an exact identity
///     apply(0.0,  factor: 0.5) == 0.25    // black lifts to a quarter, white drops to three quarters
///     apply(0.9,  factor: 1.5) == 1.0     // tones within a sixth of white clip to white
public enum SoftwareContrast {
    /// The untouched picture.
    public static let neutral: Float = 1
    /// The control's low end: black and white meet a quarter of the way in from each side, so text
    /// still reads — a factor near zero would flatten the whole screen to one grey, with nothing left
    /// to see the slider by.
    public static let minimum: Float = 0.5
    /// The control's high end, symmetric with `minimum` around neutral: a third of the tone range clips.
    public static let maximum: Float = 1.5

    /// A requested factor as the control stores it: clamped to the control's range and rounded to the
    /// whole percent the slider shows, so a drag can land exactly on neutral without any snapping
    /// window. Nil means neutral — the display's own picture.
    public static func normalized(_ factor: Float) -> Float? {
        let percent = (min(max(factor, minimum), maximum) * 100).rounded()
        let stored = percent / 100
        return stored == neutral ? nil : stored
    }

    /// The tray slider's 0...1 position for a factor; neutral sits in the middle.
    public static func position(forFactor factor: Float) -> Float {
        (min(max(factor, minimum), maximum) - minimum) / (maximum - minimum)
    }

    /// The factor at a tray slider position (0...1).
    public static func factor(forPosition position: Float) -> Float {
        minimum + min(max(position, 0), 1) * (maximum - minimum)
    }

    /// The tone curve for one input level (0...1): `clamp01(0.5 + (x − 0.5) × factor)`. Neutral
    /// returns `x` itself rather than recomputing it, so the composed table is bit-identical to the
    /// pre-contrast one when contrast is untouched.
    public static func apply(_ x: Float, factor: Float) -> Float {
        guard factor != neutral else { return x }
        return min(1, max(0, 0.5 + (x - 0.5) * factor))
    }

    /// The share of the input range this factor clips to pure black or white (0 at or below
    /// neutral): `1 − 1/factor`, split evenly between the two ends. What the "tones clip" note shows.
    public static func clippedShare(factor: Float) -> Float {
        factor > neutral ? 1 - 1 / factor : 0
    }
}

/// One display's whole software image as a single transfer: dim scale × warmth gains × contrast
/// curve × XDR boost. Every OpenDisplay control that touches the colour table is composed here and
/// written in ONE call, because a display has one gamma slot — separate writes would silently
/// overwrite each other (changing warmth must keep the dim, and vice versa).
///
/// Per channel: `out(x) = min(1, contrast(x) × boost × scale × gain)`. The floor rule is the one the
/// provider always had — the dim scale never goes below `DimmingComposer.gammaFloor`, so a gamma dim
/// cannot black a display out — extended so a lowered contrast can't undercut it: when contrast pulls
/// white below full, the scale rises just enough that the brightest output still reaches the floor.
public struct SoftwareImageTransfer: Equatable, Sendable {
    /// The gamma half of the software dim, 1 = none.
    public var dim: Float
    /// Colour-temperature gains, `.neutral` = calibration untouched.
    public var gains: ColorTemperatureCurve.Gains
    /// Software contrast factor, `SoftwareContrast.neutral` = untouched.
    public var contrast: Float
    /// XDR brightness boost (≥ 1), 1 = none.
    public var boost: Float

    public init(dim: Float, gains: ColorTemperatureCurve.Gains = .neutral,
                contrast: Float = SoftwareContrast.neutral, boost: Float = 1) {
        self.dim = dim
        self.gains = gains
        self.contrast = contrast
        self.boost = boost
    }

    /// The transfer for a display's stored state: nil kelvin/contrast mean untouched. `suspended`
    /// (AM-18) bypasses the image adjustments — temperature and contrast — while brightness keeps
    /// working: the dim and the XDR boost are expressed as usual, and the stored values themselves
    /// are untouched, so lifting the suspension restores exactly what was set. ::
    ///
    ///     composed(dim: 0.6, kelvin: 4000, contrast: 1.3, boost: 1, suspended: true)
    ///     ok: dim 0.6, gains .neutral, contrast 1 — still dimmed, no tint, no curve
    public static func composed(dim: Float, kelvin: Float?, contrast: Float?, boost: Float,
                                suspended: Bool) -> SoftwareImageTransfer {
        guard !suspended else { return SoftwareImageTransfer(dim: dim, boost: boost) }
        return SoftwareImageTransfer(
            dim: dim,
            gains: ColorTemperatureCurve.gains(kelvin: kelvin ?? ColorTemperatureCurve.neutralKelvin),
            contrast: contrast ?? SoftwareContrast.neutral,
            boost: boost)
    }

    /// Whether this differs from an untouched display at all. A neutral transfer must not be written:
    /// even an identity formula replaces the table the display's ColorSync profile installed.
    public var needsGamma: Bool {
        dim < 1 || gains != .neutral || contrast != SoftwareContrast.neutral || boost > 1
    }

    /// Whether only an explicit table can express it. The formula API clamps its coefficients to 1
    /// and cannot clip, so a boost or a contrast curve needs a table; without either, the formula
    /// path is used exactly as before.
    public var needsTable: Bool {
        effectiveBoost > 1 || contrast != SoftwareContrast.neutral
    }

    /// A boost too small to matter is no boost — the same cut-off the formula/table choice has always
    /// used, so a contrast-only table doesn't pick up a sliver of it.
    var effectiveBoost: Float { boost > 1.001 ? boost : 1 }

    /// The dim scale actually applied (see the type's floor rule).
    public var scale: Float {
        let floored = max(DimmingComposer.gammaFloor, min(1, dim))
        let white = SoftwareContrast.apply(1, factor: contrast)
        guard white < 1, white > 0 else { return floored }
        return max(floored, min(1, DimmingComposer.gammaFloor / white))
    }

    /// The per-channel coefficient: scale × that channel's gain (each gain clamped to 0...1). For a
    /// formula write this is the channel's maximum; for a table it multiplies the curve.
    public var channelScales: (red: Float, green: Float, blue: Float) {
        let scale = scale
        return (scale * min(max(gains.red, 0), 1),
                scale * min(max(gains.green, 0), 1),
                scale * min(max(gains.blue, 0), 1))
    }

    /// One channel's output for input level `x` (0...1), given that channel's coefficient.
    public func output(_ x: Float, channelScale: Float) -> Float {
        min(1, SoftwareContrast.apply(x, factor: contrast) * effectiveBoost * channelScale)
    }

    /// The three transfer tables with `count` evenly spaced entries from 0 to 1. Like the formula, an
    /// absolute re-expression from the app's own state — never a scale of whatever table is current —
    /// so repeated writes can't compound.
    public func tables(count: Int) -> (red: [Float], green: [Float], blue: [Float]) {
        let scales = channelScales
        var red = [Float](repeating: 0, count: count)
        var green = [Float](repeating: 0, count: count)
        var blue = [Float](repeating: 0, count: count)
        let last = Float(max(count - 1, 1))
        for i in 0..<count {
            let x = Float(i) / last
            red[i] = output(x, channelScale: scales.red)
            green[i] = output(x, channelScale: scales.green)
            blue[i] = output(x, channelScale: scales.blue)
        }
        return (red, green, blue)
    }
}
