import Foundation

/// One selectable display mode plus the markers the display reports for it. The exact `DisplayMode`
/// is what a mode write expects; the markers are what `DisplayMode` itself does not carry.
public struct DisplayModeOption: Hashable, Sendable, Identifiable {
    public let mode: DisplayMode
    /// The display reports this mode with the IOKit native flag. That is a reported marker only:
    /// nothing observed here establishes that the signal or the panel shows the framebuffer 1:1, so
    /// it must never be presented as "no scaling" or "the sharpest choice".
    public let isNative: Bool
    /// The mode macOS itself picks by default for this display.
    public let isDefault: Bool
    /// `CGDisplayModeIsUsableForDesktopGUI`: macOS considers the mode fit for a desktop. The ones
    /// it doesn't are still listed by Core Graphics; they are kept out of ordinary lists.
    public let isUsableForDesktop: Bool
    /// The mode's IOKit flags as Core Graphics reports them, or nil when not read (fixtures,
    /// options built without them). Only the documented public flag bits are interpreted.
    public let ioFlags: UInt32?

    public init(mode: DisplayMode, isNative: Bool, isDefault: Bool,
                isUsableForDesktop: Bool = true, ioFlags: UInt32? = nil) {
        self.mode = mode
        self.isNative = isNative
        self.isDefault = isDefault
        self.isUsableForDesktop = isUsableForDesktop
        self.ioFlags = ioFlags
    }

    // IOGraphicsTypes.h (public IOKit constants).
    static let validFlag: UInt32 = 0x0000_0001
    static let safeFlag: UInt32 = 0x0000_0002
    static let interlacedFlag: UInt32 = 0x0000_0040
    static let stretchedFlag: UInt32 = 0x0000_0800
    static let televisionFlag: UInt32 = 0x0010_0000

    /// The valid flag: false means the driver lists the mode but doesn't call it valid for this
    /// display. Nil when no flags were read.
    public var isReportedValid: Bool? { ioFlags.map { $0 & Self.validFlag != 0 } }
    /// The safe flag: false means the mode may exceed what the display is known to accept.
    public var isReportedSafe: Bool? { ioFlags.map { $0 & Self.safeFlag != 0 } }
    public var isInterlaced: Bool { (ioFlags ?? 0) & Self.interlacedFlag != 0 }
    public var isStretched: Bool { (ioFlags ?? 0) & Self.stretchedFlag != 0 }
    public var isTelevisionMode: Bool { (ioFlags ?? 0) & Self.televisionFlag != 0 }

    /// What an ordinary list offers: the modes macOS calls usable for a desktop. Everything else
    /// needs an explicit "show every mode". The valid/safe flags are shown as tags but don't hide
    /// a mode by themselves — which flags a driver sets varies, and hiding on them could empty
    /// the list of a display whose modes all work.
    public var isOrdinary: Bool { isUsableForDesktop }

    /// Exact identity: logical size, framebuffer, the unrounded refresh rate (59.94 ≠ 60) and the
    /// bit depth when it is known.
    public var id: String {
        "\(mode.pointWidth)x\(mode.pointHeight)/\(mode.pixelWidth)x\(mode.pixelHeight)@\(mode.refreshHz)"
            + (mode.bitDepth.map { "#\($0)" } ?? "")
    }
}

/// Pure choice logic behind the resolution slider: which variant stands for each size, and what a
/// stop would change about the current mode. Platform-independent so it is unit-tested; the macOS
/// layer only enumerates the modes and renders the result.
public enum DisplayModeCatalog {
    /// What moving to another mode would change besides the logical size.
    public struct Change: Hashable, Sendable {
        public var refreshRate: Bool
        public var density: Bool
        /// Only when both depths are known — an unknown depth is never reported as a change.
        public var bitDepth: Bool

        public init(refreshRate: Bool = false, density: Bool = false, bitDepth: Bool = false) {
            self.refreshRate = refreshRate
            self.density = density
            self.bitDepth = bitDepth
        }

        public var isEmpty: Bool { !refreshRate && !density && !bitDepth }
    }

    public static func change(from current: DisplayMode, to candidate: DisplayMode) -> Change {
        Change(refreshRate: !sameRefresh(current, candidate),
               density: current.isHiDPI != candidate.isHiDPI,
               bitDepth: current.bitDepth != nil && candidate.bitDepth != nil
                   && current.bitDepth != candidate.bitDepth)
    }

    /// Stops for the resolution slider: one per logical size with the panel's native aspect ratio,
    /// ascending by size so dragging right means "more space".
    ///
    /// A size-only move keeps the current format. For every size other than the current one the
    /// stop is the variant that preserves the current refresh rate, then bit depth (when known), then
    /// density — choosing native/default or HiDPI first is how a drag used to switch 59.94 Hz to
    /// 60 Hz or drop HiDPI without saying so. When no variant preserves everything the closest one
    /// is used and `change(from:to:)` names what differs, so the caller can disclose it.
    ///
    /// The current mode is always a stop, even when it is missing from `options` (macOS can leave
    /// the applied mode out of its desktop-usable list) or falls outside the aspect filter — the
    /// knob has to sit on what is actually applied rather than on a sibling or on the first stop.
    public static func sliderStops(_ options: [DisplayModeOption], current: DisplayMode?) -> [DisplayModeOption] {
        let aspect = nativeAspect(options)
        var candidates = options
        var currentOption: DisplayModeOption?
        if let current, DisplayModeChoices.isValid(current) {
            if let listed = options.first(where: { DisplayModeChoices.matches($0.mode, requested: current) }) {
                currentOption = listed
            } else {
                // Not enumerated, so nothing is known about its markers: claim none.
                let synthetic = DisplayModeOption(mode: current, isNative: false, isDefault: false)
                candidates.append(synthetic)
                currentOption = synthetic
            }
        }
        // From a LoDPI mode that has no HiDPI twin (typically a native 4K) the other sizes use
        // HiDPI where the display offers it; otherwise the current density is kept.
        let preferHiDPI = current.map { current in
            current.isHiDPI || !candidates.contains { $0.mode.isHiDPI && sameSize($0.mode, current) }
        } ?? true

        var bySize: [Size: DisplayModeOption] = [:]
        for option in candidates {
            let size = Size(option.mode)
            if let currentOption, sameSize(option.mode, currentOption.mode) {
                bySize[size] = currentOption
                continue
            }
            if let existing = bySize[size],
               rank(existing, current: current, preferHiDPI: preferHiDPI)
                >= rank(option, current: current, preferHiDPI: preferHiDPI) {
                continue
            }
            bySize[size] = option
        }
        return bySize.values
            .filter { option in
                if let currentOption, option == currentOption { return true }
                guard let aspect, option.mode.pointHeight > 0 else { return true }
                let ratio = Double(option.mode.pointWidth) / Double(option.mode.pointHeight)
                return abs(ratio - aspect) < 0.02
            }
            .sorted { lhs, rhs in
                (lhs.mode.pointWidth * lhs.mode.pointHeight, lhs.mode.pointWidth, lhs.mode.pointHeight)
                    < (rhs.mode.pointWidth * rhs.mode.pointHeight, rhs.mode.pointWidth, rhs.mode.pointHeight)
            }
    }

    /// The stop that is the current mode, matched exactly (framebuffer, density and refresh within
    /// floating-point noise) — never merely the stop with the same logical size.
    public static func index(of current: DisplayMode, in stops: [DisplayModeOption]) -> Int? {
        stops.firstIndex { DisplayModeChoices.matches($0.mode, requested: current) }
    }

    /// The panel's aspect ratio: the native-flagged mode's framebuffer, else the largest LoDPI one.
    static func nativeAspect(_ options: [DisplayModeOption]) -> Double? {
        let reference = options.first(where: \.isNative)
            ?? options.filter { !$0.mode.isHiDPI }
                .max { $0.mode.pixelWidth * $0.mode.pixelHeight < $1.mode.pixelWidth * $1.mode.pixelHeight }
        guard let mode = reference?.mode, mode.pixelHeight > 0 else { return nil }
        return Double(mode.pixelWidth) / Double(mode.pixelHeight)
    }

    /// Higher is better. With a current mode: same refresh, same depth, preferred density, then the
    /// closest refresh, then the reported native/default markers, then the larger framebuffer.
    /// Without one (nothing to preserve): markers, HiDPI, then the higher refresh.
    private static func rank(_ option: DisplayModeOption, current: DisplayMode?,
                             preferHiDPI: Bool) -> (Int, Int, Int, Double, Int, Int) {
        let mode = option.mode
        let marked = option.isNative || option.isDefault ? 1 : 0
        let framebuffer = mode.pixelWidth * mode.pixelHeight
        guard let current else {
            return (marked, mode.isHiDPI ? 1 : 0, 0, mode.refreshHz, 0, framebuffer)
        }
        let depthKept = current.bitDepth == nil || mode.bitDepth == nil || current.bitDepth == mode.bitDepth
        return (sameRefresh(mode, current) ? 1 : 0,
                depthKept ? 1 : 0,
                mode.isHiDPI == preferHiDPI ? 1 : 0,
                -abs(mode.refreshHz - current.refreshHz),
                marked,
                framebuffer)
    }

    /// The same tolerance `DisplayModeChoices.matches` uses: 59.94 and 60 stay different rates.
    private static func sameRefresh(_ lhs: DisplayMode, _ rhs: DisplayMode) -> Bool {
        abs(lhs.refreshHz - rhs.refreshHz) < 0.01
    }

    private static func sameSize(_ lhs: DisplayMode, _ rhs: DisplayMode) -> Bool {
        lhs.pointWidth == rhs.pointWidth && lhs.pointHeight == rhs.pointHeight
    }

    private struct Size: Hashable {
        let width: Int
        let height: Int
        init(_ mode: DisplayMode) { width = mode.pointWidth; height = mode.pointHeight }
    }
}
