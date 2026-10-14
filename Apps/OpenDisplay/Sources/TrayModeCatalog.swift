#if os(macOS)
import CoreGraphics
import DisplayDomain
import Foundation

/// One selectable display mode as the tray shows it: the exact `DisplayMode` that `AppModel.setMode`
/// expects, plus the panel's own markers that `DisplayMode` does not carry.
struct TrayModeOption: Hashable, Identifiable {
    let mode: DisplayMode
    /// macOS reports this framebuffer as the panel's native pixel grid (IOKit native flag) — the
    /// image is drawn 1:1, so it is the sharpest choice.
    let isNative: Bool
    /// The mode macOS itself picks by default for this display.
    let isDefault: Bool

    var id: String {
        "\(mode.pointWidth)x\(mode.pointHeight)/\(mode.pixelWidth)x\(mode.pixelHeight)@\(mode.refreshHz)"
    }
}

/// Reads the display's modes straight from Core Graphics so the tray can mark native/default modes
/// and drop the ones macOS flags as unusable for a desktop. `AppModel.allModes` keeps every mode
/// (including the "not usable for desktop GUI" ones an external monitor advertises), which put
/// low-quality modes into the old resolution list.
enum TrayModeCatalog {
    // IOGraphicsTypes.h: kDisplayModeNativeFlag / kDisplayModeDefaultFlag (public IOKit constants).
    private static let nativeFlag: UInt32 = 0x0200_0000
    private static let defaultFlag: UInt32 = 0x0000_0004

    static func options(for cgID: CGDirectDisplayID) -> [TrayModeOption] {
        let query = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(cgID, query) as? [CGDisplayMode] else { return [] }
        var seen = Set<String>()
        var result: [TrayModeOption] = []
        for cg in modes where cg.isUsableForDesktopGUI() {
            // Built exactly like CoreGraphicsProvider does, so `DisplayModeChoices.matches` accepts it.
            let mode = DisplayMode(pixelWidth: cg.pixelWidth, pixelHeight: cg.pixelHeight,
                                   pointWidth: cg.width, pointHeight: cg.height,
                                   refreshHz: cg.refreshRate, isHiDPI: cg.pixelWidth > cg.width)
            guard DisplayModeChoices.isValid(mode) else { continue }
            let option = TrayModeOption(mode: mode,
                                        isNative: cg.ioFlags & nativeFlag != 0,
                                        isDefault: cg.ioFlags & defaultFlag != 0)
            if seen.insert(option.id).inserted { result.append(option) }
        }
        return result.sorted(by: order)
    }

    /// Largest point size first (like System Settings), then HiDPI before LoDPI, then refresh.
    private static func order(_ lhs: TrayModeOption, _ rhs: TrayModeOption) -> Bool {
        let l = lhs.mode, r = rhs.mode
        if l.pointWidth * l.pointHeight != r.pointWidth * r.pointHeight {
            return l.pointWidth * l.pointHeight > r.pointWidth * r.pointHeight
        }
        if l.isHiDPI != r.isHiDPI { return l.isHiDPI }
        if l.pixelWidth != r.pixelWidth { return l.pixelWidth > r.pixelWidth }
        return l.refreshHz > r.refreshHz
    }

    /// The compact list: one row per point size. Native/default modes and the current mode are always
    /// kept; for the rest the representative keeps the current refresh rate and HiDPI-ness when it can.
    static func compact(_ options: [TrayModeOption], current: DisplayMode?) -> [TrayModeOption] {
        var bySize: [String: [TrayModeOption]] = [:]
        var order: [String] = []
        for option in options {
            let key = "\(option.mode.pointWidth)x\(option.mode.pointHeight)"
            if bySize[key] == nil { order.append(key) }
            bySize[key, default: []].append(option)
        }
        var result: [TrayModeOption] = []
        for key in order {
            guard let group = bySize[key] else { continue }
            if let current, let exact = group.first(where: { $0.mode == current }) {
                result.append(exact)
                continue
            }
            let best = group.max { score($0, current: current) < score($1, current: current) }
            if let best { result.append(best) }
        }
        return result
    }

    private static func score(_ option: TrayModeOption, current: DisplayMode?) -> (Int, Int, Int, Double) {
        let sameRefresh = current.map { abs($0.refreshHz - option.mode.refreshHz) < 0.01 } ?? false
        return (option.isDefault || option.isNative ? 1 : 0,
                option.mode.isHiDPI ? 1 : 0,
                sameRefresh ? 1 : 0,
                option.mode.refreshHz)
    }

    /// Stops for the resolution slider: one per point size with the panel's native aspect ratio
    /// (BetterDisplay's default), ascending by size so dragging right means "more space".
    static func sliderStops(_ options: [TrayModeOption], current: DisplayMode?) -> [TrayModeOption] {
        let aspect = nativeAspect(options)
        let compactList = compact(options, current: current)
        let filtered = compactList.filter { option in
            if let current, option.mode == current { return true }
            guard let aspect else { return true }
            let ratio = Double(option.mode.pointWidth) / Double(option.mode.pointHeight)
            return abs(ratio - aspect) < 0.02
        }
        return filtered.reversed()
    }

    private static func nativeAspect(_ options: [TrayModeOption]) -> Double? {
        let reference = options.first(where: \.isNative)
            ?? options.filter { !$0.mode.isHiDPI }.max { $0.mode.pixelWidth * $0.mode.pixelHeight < $1.mode.pixelWidth * $1.mode.pixelHeight }
        guard let mode = reference?.mode, mode.pixelHeight > 0 else { return nil }
        return Double(mode.pixelWidth) / Double(mode.pixelHeight)
    }

    /// Refresh rates offered at the current point size, framebuffer and density.
    static func refreshRates(_ options: [TrayModeOption], current: DisplayMode?) -> [TrayModeOption] {
        guard let current else { return [] }
        return options
            .filter {
                $0.mode.pointWidth == current.pointWidth && $0.mode.pointHeight == current.pointHeight
                    && $0.mode.pixelWidth == current.pixelWidth && $0.mode.pixelHeight == current.pixelHeight
                    && $0.mode.isHiDPI == current.isHiDPI
            }
            .sorted { $0.mode.refreshHz > $1.mode.refreshHz }
    }

    /// The same point size with the other density, if the display offers it (HiDPI toggle).
    static func densityCounterpart(_ options: [TrayModeOption], current: DisplayMode?) -> TrayModeOption? {
        guard let current else { return nil }
        return options
            .filter { $0.mode.pointWidth == current.pointWidth && $0.mode.pointHeight == current.pointHeight
                && $0.mode.isHiDPI != current.isHiDPI }
            .max { lhs, rhs in
                let l = abs(lhs.mode.refreshHz - current.refreshHz) < 0.01
                let r = abs(rhs.mode.refreshHz - current.refreshHz) < 0.01
                return (l ? 1 : 0, lhs.mode.refreshHz) < (r ? 1 : 0, rhs.mode.refreshHz)
            }
    }

    static func sizeText(_ mode: DisplayMode) -> String { "\(mode.pointWidth) × \(mode.pointHeight)" }

    static func refreshText(_ hz: Double) -> String {
        guard hz > 0 else { return "—" }
        let rounded = (hz * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? "\(Int(rounded)) Гц"
            : String(format: "%.2f Гц", locale: Locale(identifier: "ru_RU"), rounded)
    }
}
#endif
