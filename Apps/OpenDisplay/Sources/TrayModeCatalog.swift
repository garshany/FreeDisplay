#if os(macOS)
import CoreGraphics
import CoreGraphicsProvider
import DisplayDomain
import Foundation

/// One selectable display mode as the tray shows it: the exact `DisplayMode` that `AppModel.setMode`
/// expects, plus the native/default markers the display reports (see `DisplayModeOption`).
typealias TrayModeOption = DisplayModeOption

/// The tray's modes come from `DisplayModeReader`, the enumeration Settings and the information
/// report share, minus the ones macOS marks as not usable for a desktop: a tray click applies at
/// once, so those stay behind Settings' explicit "all modes" filter, which applies only through
/// Apply. `AppModel.allModes` keeps every mode unmarked, which once put low-quality modes into
/// the old resolution list.
enum TrayModeCatalog {
    static func options(for cgID: CGDirectDisplayID) -> [TrayModeOption] {
        DisplayModeReader.options(for: cgID).filter(\.isOrdinary).sorted(by: order)
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

    /// Stops for the resolution slider — see `DisplayModeCatalog.sliderStops` for how each size's
    /// variant is chosen so a size-only drag keeps the current refresh rate, depth and density.
    static func sliderStops(_ options: [TrayModeOption], current: DisplayMode?) -> [TrayModeOption] {
        DisplayModeCatalog.sliderStops(options, current: current)
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
        // Decimal separator of the UI language (59,94 in Russian, 59.94 in English).
        let number = rounded == rounded.rounded()
            ? "\(Int(rounded))"
            : String(format: "%.2f", locale: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"), rounded)
        return String(localized: "\(number) Hz")
    }
}
#endif
