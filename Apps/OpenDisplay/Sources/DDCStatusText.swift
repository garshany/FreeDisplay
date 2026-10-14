#if os(macOS)
import DisplayDomain
import Foundation

/// User-facing wording for DDC safety states, shared by the tray and the Settings detail pane so
/// both surfaces describe the same state in the same words. Whole sentences per case: a status
/// pasted together from fragments can't be translated.
enum DDCStatusText {
    /// Why OpenDisplay sends no DDC to a display (TR-06 / FB-08).
    static func refusal(_ reason: DDCBindingRefusal) -> String {
        switch reason {
        case .ambiguousIdentity:
            return String(localized: "OpenDisplay sends no DDC commands to this monitor: another connected monitor reports the same identity (usually the same model without a serial number), so it can't tell which connection belongs to which.")
        case .unidentified:
            return String(localized: "OpenDisplay sends no DDC commands to this monitor: macOS doesn't report which connection belongs to it, and with several displays attached a guess could control the wrong one.")
        case .appleDisplay:
            return String(localized: "OpenDisplay doesn't send DDC commands to Apple displays: some older models can be left with a screen that stays black. You can allow it for this display in Settings → Displays.")
        }
    }
}
#endif
