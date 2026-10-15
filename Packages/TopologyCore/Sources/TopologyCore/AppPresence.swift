import Foundation

/// When OpenDisplay shows a Dock icon (SO-13/FB-15). The bundle is a menu-bar agent
/// (`LSUIElement`); a policy only switches the running app's activation policy, so the menu-bar
/// item, open windows and any capture keep running untouched whichever way it goes.
public enum DockIconPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    /// Never in the Dock — the menu-bar item is the only standing UI.
    case never
    /// In the Dock while the Settings window is open (the default).
    case whileSettingsOpen
    /// In the Dock while any OpenDisplay window is open: Settings, About, a picture-in-picture
    /// capture, a notice or update window.
    case whileAnyWindowOpen
    /// Always in the Dock.
    case always

    /// Whether the Dock icon should be showing right now. `anyWindowOpen` counts the Settings
    /// window too; a minimised window still counts as open — it lives in the Dock.
    public func showsDockIcon(settingsWindowOpen: Bool, anyWindowOpen: Bool) -> Bool {
        switch self {
        case .never: return false
        case .whileSettingsOpen: return settingsWindowOpen
        case .whileAnyWindowOpen: return settingsWindowOpen || anyWindowOpen
        case .always: return true
        }
    }
}

/// Safe startup (FA-09): launching with Shift held — or with the `--safe-mode` argument — runs
/// one session in which OpenDisplay changes nothing on its own. Every setting, rule and restore
/// ledger stays exactly as saved; the next ordinary launch picks them all up again. Explicit
/// requests (the menu, keys, CLI, Shortcuts) still work, and so do the safety nets that bring a
/// screen back — those exist to recover from the kind of trouble safe mode is for.
public enum SafeStartup {
    /// The launch argument that asks for a safe session without holding Shift.
    public static let launchArgument = "--safe-mode"

    /// Whether this launch is a safe session.
    public static func isRequested(arguments: [String], shiftHeld: Bool) -> Bool {
        shiftHeld || arguments.contains(launchArgument)
    }

    /// An automatic behaviour a safe session holds back, in the order the banner lists them.
    public enum Suspension: String, Hashable, Sendable, CaseIterable {
        /// Protected Layout putting a drifted arrangement back.
        case layoutProtection
        /// Turning displays the user switched off back off after launch or wake.
        case turnedOffDisplays
        /// Turning the built-in off when an external display connects.
        case autoDisconnectBuiltIn
        /// Adaptive brightness and warmth, Clock Mode and the sun-position curve.
        case adaptiveDisplay
        /// Per-app brightness/contrast/colour presets.
        case appPresets
        /// Display groups carrying one member's brightness or contrast to the others.
        case displayGroupSync
        /// Paying the brightness/contrast/preset restores a previous session still owed at launch.
        case launchRestores
        /// Battery, Low Power Mode and timed XDR boost changes.
        case xdrPowerAutomation
        /// Keeping the displays awake while an external screen is attached.
        case displaySleepPrevention
    }

    /// The suspensions that hold something back under `settings` — what would have acted this
    /// session but won't. `turnedOffDisplays` says whether the app is keeping any display off.
    public static func activeSuspensions(settings: OpenDisplaySettings,
                                         turnedOffDisplays: Bool) -> [Suspension] {
        Suspension.allCases.filter { suspension in
            switch suspension {
            case .layoutProtection:
                return settings.layoutProtectionEnabled && !settings.protectedLayouts.isEmpty
            case .turnedOffDisplays:
                return turnedOffDisplays
            case .autoDisconnectBuiltIn:
                return settings.autoDisconnectBuiltInOnExternal
            case .adaptiveDisplay:
                return settings.adaptiveBrightnessSyncEnabled || settings.adaptiveWarmthEnabled
                    || settings.clockScheduleEnabled || settings.adaptiveLocationModeEnabled
            case .appPresets:
                return settings.appPresetsEnabled && !settings.appPresets.isEmpty
            case .displayGroupSync:
                return settings.defaultDisplayGroup.syncBrightness || settings.defaultDisplayGroup.syncContrast
                    || settings.displayGroups.contains {
                    ($0.syncBrightness || $0.syncContrast) && $0.memberRecordIDs.count > 1
                }
            case .launchRestores:
                return !settings.faceLightPriorStateByDisplay.isEmpty
                    || !settings.appPresetPriorStateByDisplay.isEmpty
                    || !settings.adaptiveDayPresetByDisplay.isEmpty
            case .xdrPowerAutomation:
                return settings.xdrBrightnessEnabled && (settings.xdrDisableOnBattery
                    || settings.xdrLowBatteryCutoffPercent != nil || settings.xdrDisableInLowPowerMode
                    || settings.xdrAutoOffMinutes != nil)
            case .displaySleepPrevention:
                return settings.preventDisplaySleepWithExternal
            }
        }
    }
}
