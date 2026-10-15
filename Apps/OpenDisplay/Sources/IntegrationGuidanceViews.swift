// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

// What Settings says about the two keyboard-adjacent integrations: the Shortcuts app's actions
// (SO-18) and the shortcuts macOS keeps for itself (SO-30).

// MARK: - Shortcuts app actions (SO-18)

/// The Shortcuts actions this build offers, each with what it acts on, how it reaches the display
/// and what it hands back — worded from `AutomationIntentCatalog`, so a build never lists more than
/// it can do — and the button that opens the Shortcuts app.
struct ShortcutsIntegrationRows: View {
    private static var build: AutomationIntentCatalog.Build {
        #if PUBLIC_API_ONLY
        return .publicAPIOnly
        #else
        return .full
        #endif
    }

    var body: some View {
        Text("Find these actions in the Shortcuts app’s action library. Open FreeDisplay before using display-specific actions. Reconnect All can also use its saved list of turned-off displays. Each action returns a result the next step of a shortcut can check.")
            .fixedSize(horizontal: false, vertical: true)
        ForEach(AutomationIntentCatalog.entries(for: Self.build)) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(entry.action)).font(.headline)
                Text(Self.details(entry)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        Text("These actions are separate from the keyboard shortcuts in Settings › Keyboard. To run a shortcut with keys, give it keys of its own in the Shortcuts app, in the shortcut’s details.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Button("Open Shortcuts") { Self.openShortcutsApp() }
            .disabled(Self.shortcutsAppURL == nil)
    }

    /// The action's name as the Shortcuts app shows it (the App Intent's title).
    static func title(_ action: AutomationIntentCatalog.Action) -> String {
        switch action {
        case .getBrightness: return String(localized: "Get Display Brightness")
        case .setBrightness: return String(localized: "Set Display Brightness")
        case .getDisplayMode: return String(localized: "Get Display Mode")
        case .getColorProfile: return String(localized: "Get Display Color Profile")
        case .setColorProfile: return String(localized: "Set Display Color Profile")
        case .resetColorProfile: return String(localized: "Reset Display Color Profile")
        case .setDisplayMode: return String(localized: "Set Display Mode")
        case .setMainDisplay: return String(localized: "Set Main Display")
        case .reconnectAll: return String(localized: "Reconnect All Displays")
        }
    }

    static func details(_ entry: AutomationIntentCatalog.Entry) -> String {
        var sentences: [String] = []
        switch entry.target {
        case .chosenDisplay:
            sentences.append(String(localized: "Acts on the display you choose: a connected one, or one turned off in FreeDisplay. A display that isn’t connected, or isn’t showing its own desktop, makes the action fail; another display is never used instead."))
        case .chosenDisplayOrBuiltIn:
            sentences.append(String(localized: "Acts on the display you choose: a connected one, or one turned off in FreeDisplay. A display that isn’t connected, or isn’t showing its own desktop, makes the action fail; another display is never used instead."))
            sentences.append(String(localized: "With no display chosen, it sets the built-in display."))
        case .displaysTurnedOff:
            sentences.append(String(localized: "Acts on every display turned off in FreeDisplay; there is no display to choose."))
        }
        if !entry.brightnessRoutes.isEmpty {
            if entry.brightnessRoutes == [.software] {
                sentences.append(String(localized: "This build changes brightness by software dimming only, not through the display’s own control or DDC/CI."))
            } else {
                sentences.append(String(localized: "Uses the display’s own brightness control where it has one, then the monitor’s hardware over DDC/CI, and software dimming where neither answers or where you chose it."))
            }
        }
        switch entry.result {
        case .brightness:
            sentences.append(String(localized: "Returns the display, its brightness, the level asked for, whether the display confirmed it, and how it was set."))
        case .currentMode:
            sentences.append(String(localized: "Returns the exact current display mode, including dimensions, refresh rate and HiDPI status."))
        case .colorProfile:
            sentences.append(String(localized: "Returns the profile name, custom profile path, factory-profile status and command outcome. ColorSync profile actions are available in both builds; setting a profile requires an installed profile."))
        case .displayMode:
            sentences.append(String(localized: "Returns the display, the mode, and whether the change is waiting to be kept."))
        case .mainDisplay:
            sentences.append(String(localized: "Returns the main display macOS reports afterwards, the outcome and the seconds left to keep the change."))
        case .reconnect:
            sentences.append(String(localized: "Returns the outcome and how many displays came back."))
        }
        if entry.needsKeepConfirmation {
            sentences.append(String(localized: "The change stays only if you keep it in FreeDisplay before the countdown ends."))
        }
        if entry.offersWithoutConfirmation {
            sentences.append(String(localized: "Set Display Mode offers Without confirmation, off by default. Turn it on explicitly to keep the applied mode immediately."))
        }
        return sentences.joined(separator: " ")
    }

    /// Where macOS's Shortcuts app is installed, or nil when it can't be found.
    static var shortcutsAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts")
    }

    static func openShortcutsApp() {
        guard let url = shortcutsAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Shortcuts macOS keeps (SO-30)

/// Under a recorded shortcut that macOS itself uses (Spotlight, Mission Control, screenshots…): the
/// registration may well succeed, but macOS acts on the keys first, so say so and where to change it.
struct SystemShortcutNotice: View {
    let binding: KeyBinding

    var body: some View {
        if SystemShortcutReservation.conflict(for: binding, among: SystemHotKeys.chords()) != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS uses these keys itself (System Settings › Keyboard › Keyboard Shortcuts), so FreeDisplay may never receive them. Turn the macOS shortcut off there, or choose other keys.")
                    .font(.caption).foregroundStyle(ODColor.caution)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Shortcuts…") { SystemHotKeys.openKeyboardShortcutsSettings() }
                    .controlSize(.small)
            }
        }
    }
}

/// The system shortcuts as macOS reports them (Carbon's public `CopySymbolicHotKeys`).
enum SystemHotKeys {
    static func chords() -> [SystemShortcutReservation.Chord] {
        var copied: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&copied) == noErr,
              let entries = copied?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { return nil }
            let enabled = (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue ?? false
            return SystemShortcutReservation.Chord(keyCode: code, modifiers: modifiers, enabled: enabled)
        }
    }

    /// Opens System Settings › Keyboard (the Keyboard Shortcuts button is there).
    static func openKeyboardShortcutsSettings() {
        for candidate in ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
                          "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"] {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
#endif
