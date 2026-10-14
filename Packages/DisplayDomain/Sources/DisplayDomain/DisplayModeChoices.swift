import Foundation

/// Exact discrete mode choices. Never collapses logical-size matches into a preferred
/// framebuffer/refresh/HiDPI variant and never infers physical panel resolution.
public enum DisplayModeChoices {
    public static func ordered(from modes: [DisplayMode], current: DisplayMode?) -> [DisplayMode] {
        var choices = Set(modes.filter(isValid))
        if let current, isValid(current) { choices.insert(current) }
        return choices.sorted {
            if $0.pointWidth != $1.pointWidth { return $0.pointWidth < $1.pointWidth }
            if $0.pointHeight != $1.pointHeight { return $0.pointHeight < $1.pointHeight }
            if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth < $1.pixelWidth }
            if $0.pixelHeight != $1.pixelHeight { return $0.pixelHeight < $1.pixelHeight }
            if $0.refreshHz != $1.refreshHz { return $0.refreshHz < $1.refreshHz }
            if $0.isHiDPI != $1.isHiDPI { return !$0.isHiDPI }
            return ($0.bitDepth ?? 0) < ($1.bitDepth ?? 0)
        }
    }

    /// Hide alternative non-HiDPI duplicates by default, while always keeping the observed
    /// current mode. This is a density filter, not an inference about physical panel quality.
    public static func visible(from modes: [DisplayMode], current: DisplayMode?, includeLowerDensity: Bool) -> [DisplayMode] {
        let choices = ordered(from: modes, current: current)
        guard !includeLowerDensity else { return choices }
        return choices.filter { candidate in
            candidate == current || candidate.isHiDPI || !choices.contains {
                $0.isHiDPI && $0.pointWidth == candidate.pointWidth && $0.pointHeight == candidate.pointHeight
            }
        }
    }

    /// A provider call succeeds only when warnings are empty and fresh readback matches.
    public static func verifiedApply(warnings: [String], actual: DisplayMode?, requested: DisplayMode) -> Bool {
        guard warnings.isEmpty, let actual else { return false }
        return matches(actual, requested: requested)
    }

    public static func isValid(_ mode: DisplayMode) -> Bool {
        [mode.pointWidth, mode.pointHeight, mode.pixelWidth, mode.pixelHeight]
            .allSatisfy { (1...32768).contains($0) }
            && mode.refreshHz.isFinite && (0...1000).contains(mode.refreshHz)
    }

    public static func label(_ mode: DisplayMode) -> String {
        let refresh = mode.refreshHz > 0
            ? String(format: "%.2f", locale: Locale(identifier: "ru_RU"), mode.refreshHz)
                .replacingOccurrences(of: ",00", with: "") + " Гц"
            : "частота неизвестна"
        let density = mode.isHiDPI ? "HiDPI" : "без HiDPI"
        let depth = mode.bitDepth.map { " · \($0) бит" } ?? ""
        return "\(mode.pointWidth) × \(mode.pointHeight) лог. · буфер \(mode.pixelWidth) × \(mode.pixelHeight) пикс. · \(refresh) · \(density)\(depth)"
    }

    /// Require the exact requested framebuffer and logical geometry. No pixel-only fallback,
    /// and a 59.94 Hz request must not silently select 60 Hz. Small floating-point noise is allowed.
    public static func matches(_ actual: DisplayMode, requested: DisplayMode) -> Bool {
        isValid(actual) && isValid(requested)
            && actual.pointWidth == requested.pointWidth && actual.pointHeight == requested.pointHeight
            && actual.pixelWidth == requested.pixelWidth && actual.pixelHeight == requested.pixelHeight
            && actual.isHiDPI == requested.isHiDPI
            && abs(actual.refreshHz - requested.refreshHz) < 0.01
            && (requested.bitDepth == nil || actual.bitDepth == requested.bitDepth)
    }

    /// Selection alone is harmless. A write is allowed only for a distinct, still offered mode.
    public static func canApply(_ selection: DisplayMode?, current: DisplayMode?, choices: [DisplayMode]) -> Bool {
        guard let selection, isValid(selection), selection != current else { return false }
        return choices.contains(selection)
    }
}
