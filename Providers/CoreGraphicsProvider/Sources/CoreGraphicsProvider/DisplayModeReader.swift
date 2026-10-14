#if os(macOS)
import CoreGraphics
import DisplayDomain
import Foundation

/// Every display mode Core Graphics lists for a display, with the markers it reports for each —
/// the one enumeration the tray, the Settings mode picker and the information report share, so
/// they can't disagree about what exists. Read-only: nothing here selects or applies a mode.
///
/// `kCGDisplayShowDuplicateLowResolutionModes` is passed so the scaled HiDPI ("looks like") modes
/// and their LoDPI twins are all listed; without it a built-in panel lists only a handful. Modes
/// macOS doesn't consider usable for a desktop are returned too, marked as such — choosing to
/// hide them is the caller's filter, not a gap in discovery.
public enum DisplayModeReader {
    // IOGraphicsTypes.h: kDisplayModeNativeFlag / kDisplayModeDefaultFlag (public IOKit constants).
    private static let nativeFlag: UInt32 = 0x0200_0000
    private static let defaultFlag: UInt32 = 0x0000_0004

    /// Modes in Core Graphics' order, duplicates included (`DisplayModeCatalog.distinct` folds
    /// them; `DisplayModeCatalog.summary` counts them).
    public static func listedOptions(for cgID: CGDirectDisplayID) -> [DisplayModeOption] {
        let query = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(cgID, query) as? [CGDisplayMode] else { return [] }
        return modes.compactMap { cg in
            // Built exactly like CoreGraphicsProvider's observations, so `DisplayModeChoices.matches`
            // accepts the result and a mode write finds it again.
            let mode = DisplayMode(pixelWidth: cg.pixelWidth, pixelHeight: cg.pixelHeight,
                                   pointWidth: cg.width, pointHeight: cg.height,
                                   refreshHz: cg.refreshRate, isHiDPI: cg.pixelWidth > cg.width)
            guard DisplayModeChoices.isValid(mode) else { return nil }
            return DisplayModeOption(mode: mode,
                                     isNative: cg.ioFlags & nativeFlag != 0,
                                     isDefault: cg.ioFlags & defaultFlag != 0,
                                     isUsableForDesktop: cg.isUsableForDesktopGUI(),
                                     ioFlags: cg.ioFlags)
        }
    }

    /// One option per exact mode identity.
    public static func options(for cgID: CGDirectDisplayID) -> [DisplayModeOption] {
        DisplayModeCatalog.distinct(listedOptions(for: cgID))
    }
}
#endif
