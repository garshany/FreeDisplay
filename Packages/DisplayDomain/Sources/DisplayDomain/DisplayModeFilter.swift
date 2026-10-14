// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room implementation for FreeDisplay.
import Foundation

/// A marker shown next to a mode. Each one restates something Core Graphics reported (or a plain
/// comparison with another reported mode); none is a judgement of picture quality.
public enum DisplayModeTag: Hashable, Sendable {
    case current
    /// Reported with the native flag. Not a promise of unscaled output.
    case native
    /// The mode macOS picks by default.
    case defaultMode
    /// Framebuffer larger than the logical size (rendered at 2× or more).
    case hiDPI
    /// Framebuffer equal to the logical size.
    case loDPI
    /// The framebuffer differs from the native-flagged mode's framebuffer, so something — the GPU
    /// or the display — rescales it. Only stated when the display reports a native mode.
    case scaled
    /// Listed by Core Graphics but not usable for a desktop (`CGDisplayModeIsUsableForDesktopGUI`).
    case notForDesktop
    /// The driver doesn't flag the mode as valid for this display.
    case notValid
    /// The driver doesn't flag the mode as safe for this display.
    case unsafe
    case interlaced
    case stretched
    case television
    case bitDepth(Int)
}

/// The filter categories of the mode list. Within a category the selected values are
/// alternatives (OR); different categories must all match (AND).
public enum DisplayModeFilterCategory: String, Hashable, Sendable, CaseIterable {
    case aspect, refresh, density, bitDepth
}

/// The logical aspect ratio, reduced (1920 × 1080 and 3840 × 2160 are both 16:9).
///
/// Sizes whose terms don't reduce below 100 — the notch-height sizes of MacBook panels, such as
/// 1512 × 982 = 756:491 and 1800 × 1169 — are kept at the three decimals they are shown with, so
/// sizes that read as the same ratio are one filter value rather than a row of identical labels.
public struct DisplayAspectRatio: Hashable, Sendable, Comparable {
    public let width: Int
    public let height: Int
    /// `width`/`height` hold the ratio in thousandths (1545 / 1000), not reduced terms.
    public let isDecimal: Bool

    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        if width / a < 100 && height / a < 100 {
            self.width = width / a
            self.height = height / a
            isDecimal = false
        } else {
            self.width = Int((Double(width) / Double(height) * 1000).rounded())
            self.height = 1000
            isDecimal = true
        }
    }

    public init?(_ mode: DisplayMode) { self.init(width: mode.pointWidth, height: mode.pointHeight) }

    public var value: Double { Double(width) / Double(height) }

    /// "16:9", "16:10" (rather than the reduced 8:5), "43:18", or "1.545:1".
    public func label(_ l: ReportLocalizer = .english) -> String {
        if isDecimal { return l.decimal(value, 3) + ":1" }
        if width == 8 && height == 5 { return "16:10" }
        return "\(width):\(height)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value > rhs.value }
}

/// A refresh rate at the precision mode identity uses (0.01 Hz), so 59.94 and 60 stay apart.
public struct DisplayRefreshRate: Hashable, Sendable, Comparable {
    public let centihertz: Int

    public init(_ hz: Double) { centihertz = hz.isFinite ? Int((hz * 100).rounded()) : 0 }

    public var hertz: Double { Double(centihertz) / 100 }
    /// Core Graphics reports 0 when it doesn't know the rate.
    public var isKnown: Bool { centihertz > 0 }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.centihertz > rhs.centihertz }
}

public enum DisplayModeDensity: String, Hashable, Sendable, CaseIterable {
    case hiDPI, loDPI
    public init(_ mode: DisplayMode) { self = mode.isHiDPI ? .hiDPI : .loDPI }
}

/// What the mode list shows. Changing a filter only changes the list — it never selects or
/// applies a mode, and it can't make macOS offer a mode it doesn't list.
public struct DisplayModeFilter: Hashable, Sendable {
    /// nil = any value. An empty set matches nothing (the current mode still stays visible).
    public var aspects: Set<DisplayAspectRatio>?
    public var refreshRates: Set<DisplayRefreshRate>?
    public var densities: Set<DisplayModeDensity>?
    public var bitDepths: Set<Int>?
    /// Also list the modes macOS lists but doesn't consider usable for a desktop. Applying one
    /// still goes through the confirm-or-revert step.
    public var includeNonOrdinary: Bool

    public init(aspects: Set<DisplayAspectRatio>? = nil, refreshRates: Set<DisplayRefreshRate>? = nil,
                densities: Set<DisplayModeDensity>? = nil, bitDepths: Set<Int>? = nil,
                includeNonOrdinary: Bool = false) {
        self.aspects = aspects
        self.refreshRates = refreshRates
        self.densities = densities
        self.bitDepths = bitDepths
        self.includeNonOrdinary = includeNonOrdinary
    }

    /// No category restricted; only ordinary modes.
    public static let any = DisplayModeFilter()

    /// The current mode's aspect ratio, refresh rate and density (and bit depth when known) —
    /// "modes like the one I have", the starting point for comparing alternatives.
    public static func matching(_ current: DisplayMode) -> DisplayModeFilter {
        DisplayModeFilter(aspects: DisplayAspectRatio(current).map { [$0] },
                          refreshRates: [DisplayRefreshRate(current.refreshHz)],
                          densities: [DisplayModeDensity(current)],
                          bitDepths: current.bitDepth.map { [$0] })
    }

    public var restrictedCategories: [DisplayModeFilterCategory] {
        var result: [DisplayModeFilterCategory] = []
        if aspects != nil { result.append(.aspect) }
        if refreshRates != nil { result.append(.refresh) }
        if densities != nil { result.append(.density) }
        if bitDepths != nil { result.append(.bitDepth) }
        return result
    }

    /// The categories `mode` fails. An unknown depth never fails a depth selection it can't be
    /// compared with — it fails only because it is unknown, which is said as such elsewhere.
    public func failedCategories(_ mode: DisplayMode) -> [DisplayModeFilterCategory] {
        var failed: [DisplayModeFilterCategory] = []
        if let aspects, !(DisplayAspectRatio(mode).map(aspects.contains) ?? false) { failed.append(.aspect) }
        if let refreshRates, !refreshRates.contains(DisplayRefreshRate(mode.refreshHz)) { failed.append(.refresh) }
        if let densities, !densities.contains(DisplayModeDensity(mode)) { failed.append(.density) }
        if let bitDepths, !(mode.bitDepth.map(bitDepths.contains) ?? false) { failed.append(.bitDepth) }
        return failed
    }

    public func matches(_ mode: DisplayMode) -> Bool { failedCategories(mode).isEmpty }

    /// Adds or removes one value; starting from "any" selects just that value.
    public mutating func toggle(_ value: DisplayAspectRatio) { aspects = Self.toggled(aspects, value) }
    public mutating func toggle(_ value: DisplayRefreshRate) { refreshRates = Self.toggled(refreshRates, value) }
    public mutating func toggle(_ value: DisplayModeDensity) { densities = Self.toggled(densities, value) }
    public mutating func toggle(bitDepth value: Int) { bitDepths = Self.toggled(bitDepths, value) }

    private static func toggled<T: Hashable>(_ set: Set<T>?, _ value: T) -> Set<T> {
        guard var set else { return [value] }
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
        return set
    }
}

extension DisplayModeCatalog {
    /// The values each filter category can take for these modes. Depth appears only when some
    /// mode reports one; the provider never guesses it.
    public struct Facets: Hashable, Sendable {
        public var aspects: [DisplayAspectRatio]
        public var refreshRates: [DisplayRefreshRate]
        public var densities: [DisplayModeDensity]
        public var bitDepths: [Int]
    }

    public static func facets(_ options: [DisplayModeOption]) -> Facets {
        let modes = options.map(\.mode)
        return Facets(aspects: Set(modes.compactMap(DisplayAspectRatio.init)).sorted(),
                      refreshRates: Set(modes.map { DisplayRefreshRate($0.refreshHz) }).sorted(),
                      densities: DisplayModeDensity.allCases.filter { density in
                          modes.contains { DisplayModeDensity($0) == density } },
                      bitDepths: Set(modes.compactMap(\.bitDepth)).sorted())
    }

    /// One option per exact mode identity. Core Graphics can list the same logical size,
    /// framebuffer and rate more than once (variants that differ only in properties a mode write
    /// can't select between); the first is kept, unless a later twin is ordinary and it isn't —
    /// a list shouldn't call a mode unusable when an equally selectable twin is fine.
    public static func distinct(_ options: [DisplayModeOption]) -> [DisplayModeOption] {
        var index: [String: Int] = [:]
        var result: [DisplayModeOption] = []
        for option in options {
            if let existing = index[option.id] {
                if !result[existing].isOrdinary && option.isOrdinary { result[existing] = option }
            } else {
                index[option.id] = result.count
                result.append(option)
            }
        }
        return result
    }

    /// The framebuffer of the native-flagged mode (the largest one if several are flagged), or
    /// nil when the display flags none — then "scaled" can't be said of any mode.
    public static func nativeFramebuffer(_ options: [DisplayModeOption]) -> (width: Int, height: Int)? {
        options.filter(\.isNative)
            .max { $0.mode.pixelWidth * $0.mode.pixelHeight < $1.mode.pixelWidth * $1.mode.pixelHeight }
            .map { ($0.mode.pixelWidth, $0.mode.pixelHeight) }
    }

    /// The markers for one mode, in display order.
    public static func tags(for option: DisplayModeOption, among options: [DisplayModeOption],
                            current: DisplayMode?) -> [DisplayModeTag] {
        var tags: [DisplayModeTag] = []
        if let current, DisplayModeChoices.matches(option.mode, requested: current) { tags.append(.current) }
        if option.isNative { tags.append(.native) }
        if option.isDefault { tags.append(.defaultMode) }
        tags.append(option.mode.isHiDPI ? .hiDPI : .loDPI)
        if let native = nativeFramebuffer(options),
           native.width != option.mode.pixelWidth || native.height != option.mode.pixelHeight {
            tags.append(.scaled)
        }
        if let depth = option.mode.bitDepth { tags.append(.bitDepth(depth)) }
        if option.isInterlaced { tags.append(.interlaced) }
        if option.isStretched { tags.append(.stretched) }
        if option.isTelevisionMode { tags.append(.television) }
        if !option.isUsableForDesktop { tags.append(.notForDesktop) }
        if option.isReportedValid == false { tags.append(.notValid) }
        if option.isReportedSafe == false { tags.append(.unsafe) }
        return tags
    }

    public struct FilterResult: Hashable, Sendable {
        /// The modes to list, in input order; the current mode is always among them.
        public var visible: [DisplayModeOption]
        /// Why the current mode is listed although an ordinary list wouldn't show it: the
        /// category filters exclude it, macOS marks it not for desktop use, or macOS didn't
        /// enumerate it at all.
        public var currentFailsFilters: Bool
        public var currentIsNotOrdinary: Bool
        public var currentNotEnumerated: Bool
        /// Ordinary (or included) modes the category filters hide — what clearing them reveals.
        public var hiddenByFilters: Int
        /// Modes hidden because macOS marks them not for desktop use, whatever the filters say.
        public var hiddenNonOrdinary: Int

        public var currentKeptOutsideFilter: Bool {
            currentFailsFilters || currentIsNotOrdinary || currentNotEnumerated
        }
    }

    public static func filter(_ options: [DisplayModeOption], with filter: DisplayModeFilter,
                              current: DisplayMode?) -> FilterResult {
        var result = FilterResult(visible: [], currentFailsFilters: false, currentIsNotOrdinary: false,
                                  currentNotEnumerated: false, hiddenByFilters: 0, hiddenNonOrdinary: 0)
        var currentListed = false
        for option in options {
            let isCurrent = current.map { DisplayModeChoices.matches(option.mode, requested: $0) } ?? false
            let passes = filter.matches(option.mode)
            let allowed = option.isOrdinary || filter.includeNonOrdinary
            if isCurrent {
                // Only the first enumerated twin stands for the current mode.
                guard !currentListed else { continue }
                currentListed = true
                result.currentFailsFilters = !passes
                result.currentIsNotOrdinary = !allowed
                result.visible.append(option)
            } else if !allowed {
                result.hiddenNonOrdinary += 1
            } else if !passes {
                result.hiddenByFilters += 1
            } else {
                result.visible.append(option)
            }
        }
        if let current, !currentListed, DisplayModeChoices.isValid(current) {
            // Not enumerated, so nothing is known about its markers: claim none.
            result.visible.insert(DisplayModeOption(mode: current, isNative: false, isDefault: false), at: 0)
            result.currentNotEnumerated = true
        }
        return result
    }

    /// Why a mode is or isn't in the list.
    public enum Availability: Hashable, Sendable {
        case listed
        /// Offered, but these filter categories hide it.
        case hiddenByFilters([DisplayModeFilterCategory])
        /// Offered, but not ordinary: these tags say why. Including all modes lists it.
        case hiddenNotOrdinary([DisplayModeTag])
        /// macOS doesn't offer it on this display right now. Filters can't add it.
        case notOffered(Alternatives)
    }

    /// What macOS does offer at the same logical size, so "missing" can say what is near.
    public struct Alternatives: Hashable, Sendable {
        /// Same logical size, framebuffer and density at other refresh rates.
        public var otherRefreshRates: [Double]
        /// Same logical size with the other density.
        public var otherDensityOffered: Bool
        /// Same logical size and density with a different framebuffer.
        public var otherFramebufferOffered: Bool
        /// Nothing at this logical size at all.
        public var sizeNotOffered: Bool { otherRefreshRates.isEmpty && !otherDensityOffered && !otherFramebufferOffered }
    }

    public static func availability(of wanted: DisplayMode, in options: [DisplayModeOption],
                                    filter: DisplayModeFilter) -> Availability {
        if let option = options.first(where: { DisplayModeChoices.matches($0.mode, requested: wanted) }) {
            let failed = filter.failedCategories(option.mode)
            if !failed.isEmpty { return .hiddenByFilters(failed) }
            if !option.isOrdinary && !filter.includeNonOrdinary {
                let reasons = tags(for: option, among: options, current: nil).filter {
                    $0 == .notForDesktop || $0 == .notValid || $0 == .unsafe
                }
                return .hiddenNotOrdinary(reasons)
            }
            return .listed
        }
        let sameSize = options.map(\.mode).filter {
            $0.pointWidth == wanted.pointWidth && $0.pointHeight == wanted.pointHeight
        }
        let sameFramebuffer = sameSize.filter {
            $0.pixelWidth == wanted.pixelWidth && $0.pixelHeight == wanted.pixelHeight && $0.isHiDPI == wanted.isHiDPI
        }
        let rates = Set(sameFramebuffer.map { DisplayRefreshRate($0.refreshHz) }).sorted().map(\.hertz)
        return .notOffered(Alternatives(
            otherRefreshRates: rates,
            otherDensityOffered: sameSize.contains { $0.isHiDPI != wanted.isHiDPI },
            otherFramebufferOffered: sameSize.contains {
                $0.isHiDPI == wanted.isHiDPI && ($0.pixelWidth != wanted.pixelWidth || $0.pixelHeight != wanted.pixelHeight)
            }))
    }

    /// Counts that describe what macOS enumerated for a display.
    public struct DiscoverySummary: Hashable, Sendable {
        /// Entries as Core Graphics listed them, duplicates included.
        public var listed: Int
        public var distinct: Int
        public var ordinary: Int
        public var notForDesktop: Int
        public var flaggedInvalid: Int
        public var flaggedUnsafe: Int
        public var hiDPI: Int
        public var loDPI: Int
        public var duplicates: Int { listed - distinct }
    }

    public static func summary(listed raw: [DisplayModeOption]) -> DiscoverySummary {
        let unique = distinct(raw)
        return DiscoverySummary(
            listed: raw.count, distinct: unique.count,
            ordinary: unique.filter(\.isOrdinary).count,
            notForDesktop: unique.filter { !$0.isUsableForDesktop }.count,
            flaggedInvalid: unique.filter { $0.isReportedValid == false }.count,
            flaggedUnsafe: unique.filter { $0.isReportedSafe == false }.count,
            hiDPI: unique.filter(\.mode.isHiDPI).count,
            loDPI: unique.filter { !$0.mode.isHiDPI }.count)
    }

    /// Words for a tag, via the report localizer (the app passes its catalog).
    public static func tagLabel(_ tag: DisplayModeTag, _ l: ReportLocalizer = .english) -> String {
        switch tag {
        case .current: return l("current")
        case .native: return l("native")
        case .defaultMode: return l("default")
        case .hiDPI: return "HiDPI"
        case .loDPI: return "LoDPI"
        case .scaled: return l("scaled")
        case .notForDesktop: return l("not for desktop use")
        case .notValid: return l("not flagged valid")
        case .unsafe: return l("not flagged safe")
        case .interlaced: return l("interlaced")
        case .stretched: return l("stretched")
        case .television: return l("TV mode")
        case .bitDepth(let bits): return l.fill("%1-bit", "\(bits)")
        }
    }
}
