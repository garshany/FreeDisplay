import Foundation

/// How far one brightness or volume step moves a ranged control (SO-29), shared by the native media
/// keys and the custom keyboard shortcuts so the two never disagree about what "one step" is.
///
/// The span of a control is divided into `range` logical intervals; a standard step moves
/// `standard` of them and a fine step `fine`. The defaults (64 / 4 / 1) are macOS's own 1/16 and
/// 1/64 steps. Each stored value is an independent override: nil (a blank field) means that one
/// value's default, and a stored value that can't describe a step — zero or negative — stays stored
/// (so the editor can show what was typed) while the default applies in its place.
///
/// These are the fractions OpenDisplay *requests*; hardware that quantises more coarsely (a monitor
/// with ten DDC brightness levels, an audio device with fixed increments) can still round them.
public struct AdjustmentSteps: Hashable, Sendable, Codable {
    public static let defaultRange = 64
    public static let defaultStandard = 4
    public static let defaultFine = 1

    /// Logical intervals across the full span; nil = `defaultRange`.
    public var range: Int?
    /// Intervals one standard step moves; nil = `defaultStandard`.
    public var standard: Int?
    /// Intervals one fine step moves; nil = `defaultFine`.
    public var fine: Int?
    /// When on, the native keys take fine steps and ⇧⌥ switches them to standard steps — the reverse
    /// of the default. Explicit standard/fine shortcut actions are not affected.
    public var fineByDefault: Bool

    public init(range: Int? = nil, standard: Int? = nil, fine: Int? = nil, fineByDefault: Bool = false) {
        self.range = range
        self.standard = standard
        self.fine = fine
        self.fineByDefault = fineByDefault
    }

    public static let `default` = AdjustmentSteps()

    public var effectiveRange: Int { Self.usable(range) ?? Self.defaultRange }
    public var effectiveStandard: Int { Self.usable(standard) ?? Self.defaultStandard }
    public var effectiveFine: Int { Self.usable(fine) ?? Self.defaultFine }

    /// The share of the full span one step moves. A step larger than the whole span moves the whole
    /// span: a ranged control has nowhere further to go.
    public func fraction(fine: Bool) -> Float {
        let intervals = fine ? effectiveFine : effectiveStandard
        return min(1, Float(intervals) / Float(effectiveRange))
    }

    /// The step a native brightness/volume key takes: ⇧⌥ (`modifierRequestsFine`) asks for the step
    /// that isn't the default one.
    public func nativeKeyFraction(modifierRequestsFine: Bool) -> Float {
        fraction(fine: modifierRequestsFine != fineByDefault)
    }

    /// Reads one field's text: blank or unparseable text is "no override" (the field's default),
    /// anything numeric is kept as typed. Surrounding whitespace is ignored.
    public static func parse(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A stored value that can describe a step: at least one interval.
    private static func usable(_ value: Int?) -> Int? {
        guard let value, value >= 1 else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey { case range, standard, fine, fineByDefault }

    /// Tolerant, like the settings file around it: a missing or unreadable field is its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        range = (try? container.decodeIfPresent(Int.self, forKey: .range)) ?? nil
        standard = (try? container.decodeIfPresent(Int.self, forKey: .standard)) ?? nil
        fine = (try? container.decodeIfPresent(Int.self, forKey: .fine)) ?? nil
        fineByDefault = ((try? container.decodeIfPresent(Bool.self, forKey: .fineByDefault)) ?? nil) ?? false
    }
}
