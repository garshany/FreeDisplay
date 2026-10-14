#if os(macOS)
import AutomationSchema
import DisplayDomain
import Foundation
import TopologyCore

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

    // MARK: - Power (AM-04 / SD-03)

    /// Title of the confirmation for a disruptive power command.
    static func powerConfirmTitle(_ mode: DDCPowerMode, displayName: String) -> String {
        switch mode {
        case .off: return String(localized: "Turn off “\(displayName)” over DDC?")
        case .standby, .on: return String(localized: "Put “\(displayName)” in standby over DDC?")
        }
    }

    /// Label of the button that confirms and sends the command.
    static func powerConfirmButton(_ mode: DDCPowerMode) -> String {
        switch mode {
        case .off: return String(localized: "Turn Off")
        case .standby, .on: return String(localized: "Put in Standby")
        }
    }

    /// What the command does and how to recover, stronger when the display hosts the menu bar or is
    /// the last screen with a picture — a DDC power command leaves macOS's arrangement untouched.
    static func powerWarning(_ mode: DDCPowerMode, risk: DDCPowerRisk) -> String {
        let action: String
        switch mode {
        case .off:
            action = String(localized: "The monitor is asked to power down. Many monitors can't be turned back on over DDC — only with their own power button.")
        case .standby, .on:
            action = String(localized: "The monitor is asked to blank its picture. Some monitors don't wake again over DDC — then only their power button brings the picture back.")
        }
        switch risk {
        case .otherScreensRemain:
            return action
        case .mainDisplay:
            return action + " " + String(localized: "This is the main display: the menu bar and Dock stay on it while it is dark. Use the monitor's power button to get them back.")
        case .onlyScreen:
            return action + " " + String(localized: "This is the only screen showing a picture. If it doesn't wake, you'll have no screen to work with until you press the monitor's power button.")
        }
    }

    /// What the transport reported for a power command — never "done": the effect can't be read back.
    static func powerOutcome(_ outcome: DDCCommandOutcome, mode: DDCPowerMode) -> String {
        switch outcome {
        case .sent:
            return String(localized: "“\(mode.label.appLocalized)” sent. The monitor accepted the command; OpenDisplay can't check whether the screen actually changed.")
        case .failed:
            return String(localized: "The monitor didn't accept the “\(mode.label.appLocalized)” command (DDC write failed). Nothing changed.")
        case .notSent:
            return notSent
        }
    }

    private static var notSent: String {
        String(localized: "Nothing was sent: OpenDisplay has no usable DDC connection to this monitor.")
    }

    // MARK: - Factory reset (AM-06)

    /// What the monitor's factory reset reported. The app's own dimming/temperature are untouched
    /// either way; the UI offers them as a separate action after a reset that went through.
    static func resetOutcome(_ outcome: DDCCommandOutcome) -> String {
        switch outcome {
        case .sent:
            return String(localized: "Factory reset sent — the monitor accepted the command, and its controls were read again.")
        case .failed:
            return String(localized: "The monitor didn't accept the factory reset (DDC write failed). Nothing was changed, including OpenDisplay's own dimming and temperature.")
        case .notSent:
            return notSent
        }
    }

    // MARK: - Volume and mute (TB-02 / TB-03)

    /// Tooltip of a monitor volume slider, saying what its speaker icon really does.
    static func volumeHelp(_ mute: DDCAudioPolicy.MuteAction) -> String {
        switch mute {
        case .discrete:
            return String(localized: "Monitor volume over DDC. Click the icon to mute or unmute the monitor.")
        case .zeroVolume, .restore:
            return String(localized: "Monitor volume over DDC. This monitor has no readable mute, so the icon sets the volume to 0 and back to the previous level.")
        case .unavailable:
            return String(localized: "Monitor volume over DDC. There's no earlier level to restore — raise the volume with the slider.")
        }
    }

    /// Shown under a control whose last write never reached the monitor.
    static var writeFailed: String {
        String(localized: "The last change didn't reach the monitor (DDC write failed).")
    }

    // MARK: - Input source (AM-05)

    /// The last input request and what became of it — always worded as a request, because a sent
    /// switch is not a confirmed one (the monitor often stops answering on this Mac's input).
    static func inputSwitch(_ request: DDCInputSwitch, inputName: String) -> String {
        switch request.status {
        case .sending: return String(localized: "Switching to \(inputName)…")
        case .sent: return String(localized: "Switch to \(inputName) sent — the monitor hasn't confirmed it.")
        case .failed: return String(localized: "The monitor didn't accept the switch to \(inputName) (DDC write failed).")
        case .notSent: return notSent
        }
    }
}
#endif
