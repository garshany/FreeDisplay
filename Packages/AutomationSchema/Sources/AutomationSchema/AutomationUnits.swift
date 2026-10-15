import Foundation

/// The one canonical representation of a ranged control's level (brightness today; any 0…1 control
/// later): a normalized fraction of the control's span, 0 = its minimum, 1 = its maximum (FD-066).
///
/// Every surface converts at its edge and nowhere else: the CLI and HTTP take `0.4` or `40%`, App
/// Intents take whole percent, DDC speaks the monitor's raw units. Internally a level is always
/// this type, so "25" can never be read as 25 % on one surface and refused on another. A level is
/// a share of the *control's* span — 0.4 on a DDC route is 40 % of the monitor's reported maximum —
/// never a luminance or nits claim.
public struct AutomationLevel: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    /// 0…1, finite.
    public let normalized: Double

    /// Nil for a non-finite value or one outside 0…1 — out-of-range input is refused, not clamped,
    /// so a typo never silently becomes the minimum or maximum.
    public init?(normalized: Double) {
        guard normalized.isFinite, (0...1).contains(normalized) else { return nil }
        self.normalized = normalized
    }

    /// Clamps into 0…1 — only for results of arithmetic on valid levels (an offset past the end of
    /// the span lands on the end). A non-finite input clamps to 0.
    public init(clamping value: Double) {
        normalized = value.isFinite ? min(1, max(0, value)) : 0
    }

    /// A percentage of the span (0…100), or nil outside it.
    public init?(percent: Double) {
        self.init(normalized: percent / 100)
    }

    /// A level in a control's own integer units (`current` of `maximum`), e.g. a DDC reading.
    /// Nil when the maximum is not positive or the value lies outside the span.
    public init?(raw current: Int, maximum: Int) {
        guard maximum > 0 else { return nil }
        self.init(normalized: Double(current) / Double(maximum))
    }

    public static let minimum = AutomationLevel(clamping: 0)
    public static let maximum = AutomationLevel(clamping: 1)

    /// The level in percent of the span, unrounded.
    public var percent: Double { normalized * 100 }

    /// The level in whole percent — what App Intents and slider captions speak.
    public var wholePercent: Int { Int((normalized * 100).rounded()) }

    /// The level as the Float the app's brightness funnel and the providers take.
    public var float: Float { Float(normalized) }

    /// The level in a control's own integer units, rounded to the nearest unit — the conversion the
    /// app and the CLI both use to turn a level into a DDC target.
    public func raw(maximum: Int) -> Int { Int((normalized * Double(maximum)).rounded()) }

    /// This level moved by `delta`, landing on the end of the span when it would pass it.
    public func offset(by delta: AutomationLevelDelta) -> AutomationLevel {
        AutomationLevel(clamping: normalized + delta.normalized)
    }

    public static func < (lhs: AutomationLevel, rhs: AutomationLevel) -> Bool { lhs.normalized < rhs.normalized }

    public var description: String { String(format: "%.4g", normalized) }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Double.self)
        guard let level = AutomationLevel(normalized: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "level must be 0…1"))
        }
        self = level
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(normalized)
    }
}

/// A signed relative change of a level, in the same normalized unit: +0.05 is five percentage points
/// of the span (FA-44). Relative change is only ever requested explicitly (an `offset` parameter);
/// a minus sign on an absolute value is never read as one.
public struct AutomationLevelDelta: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Any finite signed change; arithmetic clamps only the resulting level.
    public let normalized: Double

    /// Nil only for a non-finite value. The caller chooses the adjustment size.
    public init?(normalized: Double) {
        guard normalized.isFinite else { return nil }
        self.normalized = normalized
    }

    public init?(percentagePoints: Double) {
        self.init(normalized: percentagePoints / 100)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Double.self)
        guard let delta = Self(normalized: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "offset must be finite")
        }
        self = delta
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(normalized)
    }

    public var percentagePoints: Double { normalized * 100 }

    public var description: String { String(format: "%+.4g", normalized) }
}

/// Parses the textual forms every surface accepts into the canonical units. One grammar:
///
/// - level: `0.4` (normalized) or `40%` / `40 %` (percent). A bare number outside 0…1 is refused —
///   `25` is not 25 % — so the unit is always explicit.
/// - delta: `+0.05`, `-0.05`, `+5%`, `-5%`; an unsigned value is an increase.
/// - raw: a control's own integer units, decimal (`70`) or hexadecimal (`0x46`), 0…65535 (the
///   16-bit width of a DDC value).
///
/// Only `.` is a decimal separator: automation input is machine text, never locale-formatted.
public enum AutomationValueParser {
    public static func level(_ text: String, parameter: String = "value") throws(AutomationIssue) -> AutomationLevel {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let percentText = stripPercent(trimmed) {
            guard let percent = decimal(percentText), let level = AutomationLevel(percent: percent) else {
                throw .invalidValue(parameter, "'\(text)' is not a percentage from 0% to 100%")
            }
            return level
        }
        guard let value = decimal(trimmed) else {
            throw .invalidValue(parameter, "'\(text)' is not a level (use 0…1, or a percentage like 40%)")
        }
        return try level(number: value, parameter: parameter, original: text)
    }

    /// A JSON or Intent number, read as a normalized level.
    public static func level(number: Double, parameter: String = "value",
                             original: String? = nil) throws(AutomationIssue) -> AutomationLevel {
        guard let level = AutomationLevel(normalized: number) else {
            let shown = original ?? String(number)
            throw .invalidValue(parameter, "'\(shown)' is outside 0…1 (for a percentage write it with %, e.g. 40%)")
        }
        return level
    }

    public static func delta(_ text: String, parameter: String = "offset") throws(AutomationIssue) -> AutomationLevelDelta {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let percentText = stripPercent(trimmed) {
            guard let points = signedDecimal(percentText), let delta = AutomationLevelDelta(percentagePoints: points) else {
                throw .invalidValue(parameter, "'\(text)' is not a finite percentage-point change")
            }
            return delta
        }
        guard let value = signedDecimal(trimmed) else {
            throw .invalidValue(parameter, "'\(text)' is not a change (use e.g. +0.05, -0.05, +5% or -5%)")
        }
        return try delta(number: value, parameter: parameter, original: text)
    }

    public static func delta(number: Double, parameter: String = "offset",
                             original: String? = nil) throws(AutomationIssue) -> AutomationLevelDelta {
        guard let delta = AutomationLevelDelta(normalized: number) else {
            throw .invalidValue(parameter, "'\(original ?? String(number))' is not a finite change")
        }
        return delta
    }

    public static func rawValue(_ text: String, parameter: String = "value") throws(AutomationIssue) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let parsed: Int?
        if trimmed.hasPrefix("0x") {
            let digits = trimmed.dropFirst(2)
            parsed = digits.isEmpty ? nil : Int(digits, radix: 16)
        } else {
            parsed = trimmed.allSatisfy(\.isASCII) ? Int(trimmed) : nil
        }
        guard let value = parsed, (0...0xFFFF).contains(value) else {
            throw .invalidValue(parameter, "'\(text)' is not a raw value 0–65535 (decimal or 0x hex)")
        }
        return value
    }

    // MARK: Helpers

    private static func stripPercent(_ text: String) -> String? {
        guard text.hasSuffix("%") else { return nil }
        return String(text.dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// An unsigned decimal number: digits with at most one `.`, nothing else (no exponent, no sign,
    /// no locale separators), so every accepted spelling has one obvious meaning.
    private static func decimal(_ text: String) -> Double? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              text.filter({ $0 == "." }).count <= 1, text != "." else { return nil }
        return Double(text)
    }

    private static func signedDecimal(_ text: String) -> Double? {
        if text.hasPrefix("+") { return decimal(String(text.dropFirst())) }
        if text.hasPrefix("-") { return decimal(String(text.dropFirst())).map { -$0 } }
        return decimal(text)
    }
}
