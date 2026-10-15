// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// Settings → Keyboard → native keys (SO-25, SO-26, SO-27, SO-28, FA-19, FA-20, TA-06): whether the
/// keyboard's brightness and volume keys are captured — each set on its own — when they are taken
/// from macOS, which displays they change, the native-audio fallback, the mute pass-through and the
/// release feedback sound, with permission, listening and audio engagement shown as separate facts.
struct NativeKeyboardControlCard: View {
    @EnvironmentObject private var model: AppModel

    private var keys: NativeKeyPreferences { model.settings.nativeKeys }

    private func binding<Value>(_ keyPath: WritableKeyPath<NativeKeyPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.settings.nativeKeys[keyPath: keyPath] },
                set: { value in model.updateNativeKeyPreferences { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            Text("Brightness and volume keys").font(.title3)
            Toggle(isOn: Binding(get: { model.settings.mediaKeyInterceptionEnabled },
                                 set: { model.setMediaKeyInterceptionEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use the brightness & volume keys to control displays")
                    Text("Capturing the keys needs Accessibility permission; nothing is requested until you turn this on. A key FreeDisplay can’t act on keeps working as usual.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.settings.mediaKeyInterceptionEnabled {
                listeningStatus
                brightnessSection
                volumeSection
                Text("While FreeDisplay handles a key: ⇧ changes only the chosen displays — group sync is skipped, and “All displays” narrows to the one under the pointer; ⇧⌥ takes the other step size; ⌃ picks the built-in display, ⌃⌘ the external displays, and ⇧⌘ every display except the one under the pointer. ⌥ opens Displays or Sound settings. ⌘ with brightness down stops mirroring; ⌘ with brightness up mirrors the first available external display to the main display. Other combinations go to macOS.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refreshAudioOutputs() }
    }

    // MARK: - Listening

    @ViewBuilder private var listeningStatus: some View {
        switch model.nativeKeyListeningState {
        case .off:
            Text("Neither the brightness nor the volume keys are captured, so no permission is needed.")
                .font(.caption).foregroundStyle(.secondary)
        case .permissionMissing:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ODColor.caution)
                Text("FreeDisplay needs Accessibility permission to capture the keys. Until then they work as usual.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Accessibility Settings…") { Self.openSystemSettings("com.apple.preference.security?Privacy_Accessibility") }
                    .controlSize(.small)
            }
        case .waitingForCapture:
            HStack(spacing: 8) {
                Text("Permission is granted, but the keys aren’t captured yet. FreeDisplay keeps trying; relaunching it also helps.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry Key Capture") { model.retryMediaKeyCapture() }
                    .controlSize(.small)
                Button("Relaunch FreeDisplay") { AppLanguage.relaunch() }
                    .controlSize(.small)
            }
        case .listening:
            Label("Listening for the keys", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(ODColor.connected)
        }
    }

    // MARK: - Brightness

    @ViewBuilder private var brightnessSection: some View {
        Text("Brightness keys").font(.headline).padding(.top, ODSpacing.xs)
        Toggle("Capture the brightness keys", isOn: binding(\.brightnessKeysEnabled))
        if keys.brightnessKeysEnabled {
            Picker("Brightness keys control the", selection: Binding(
                get: { model.settings.mediaKeyTargetMode }, set: { model.setMediaKeyTargetMode($0) })) {
                Text("Display under the pointer").tag(MediaKeyTargetMode.underCursor)
                Text("Display with the focused window").tag(MediaKeyTargetMode.focusedWindow)
                Text("All displays").tag(MediaKeyTargetMode.allDisplays)
                Text("Main display").tag(MediaKeyTargetMode.mainDisplay)
                Text("Built-in display").tag(MediaKeyTargetMode.builtInAlways)
                Text("External displays only").tag(MediaKeyTargetMode.externalOnly)
            }
            .fixedSize()
            Picker("Take the brightness keys", selection: binding(\.brightnessTakeover)) {
                Text("For any display FreeDisplay can control").tag(BrightnessKeyTakeover.anyControllableDisplay)
                Text("Only for displays macOS can’t adjust itself").tag(BrightnessKeyTakeover.onlyWhenMacOSCannot)
            }
            .fixedSize()
            Text("Ordinary brightness keys respect each display’s keyboard control setting. ⇧⌘ can also change excluded displays. With no display to change, the key goes to macOS. When macOS keeps a key, its own targeting and steps apply.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Use fine steps by default for brightness", isOn: Binding(
                get: { keys.brightnessFineByDefault ?? model.settings.adjustmentSteps.fineByDefault },
                set: { value in model.updateNativeKeyPreferences { $0.brightnessFineByDefault = value } }))
            if keys.brightnessFineByDefault != nil {
                Button("Use shared step default") { model.updateNativeKeyPreferences { $0.brightnessFineByDefault = nil } }
            }
            Toggle("Require Shift for the brightness keys", isOn: Binding(
                get: { model.settings.brightnessMediaKeysRequireShift },
                set: { model.setBrightnessMediaKeysRequireShift($0) }))
            Toggle(isOn: binding(\.alternativeBrightnessKeys)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("F14 and F15 change brightness too")
                    Text("Scroll Lock and Pause on many PC keyboards send F14 and F15. A shortcut you recorded with one of these keys keeps working.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Volume

    @ViewBuilder private var volumeSection: some View {
        Text("Volume and mute keys").font(.headline).padding(.top, ODSpacing.xs)
        Toggle("Capture the volume and mute keys", isOn: binding(\.volumeKeysEnabled))
        if keys.volumeKeysEnabled {
            Text(audioStatusText).font(.caption).foregroundStyle(.secondary)
            Text(currentOutputText).font(.caption).foregroundStyle(.secondary)
            Picker("Take the volume keys when", selection: binding(\.audioEngagement)) {
                Text("The current output belongs to a display").tag(AudioKeyEngagement.outputMatchesDisplay)
                Text("The current output has no volume control").tag(AudioKeyEngagement.outputLacksVolumeControl)
                Text("A display with sound control is connected").tag(AudioKeyEngagement.anyControllableDisplay)
                Text("Always").tag(AudioKeyEngagement.always)
            }
            .fixedSize()
            Picker("Volume keys change", selection: binding(\.audioTarget)) {
                Text("Displays the current output belongs to").tag(AudioKeyTargetMode.matchingOutput)
                Text("Display under the pointer").tag(AudioKeyTargetMode.underCursor)
                Text("Display with the focused window").tag(AudioKeyTargetMode.focusedWindow)
                Text("All displays with sound control").tag(AudioKeyTargetMode.allDisplays)
            }
            .fixedSize()
            Text("Which output belongs to a display, and which output a display’s volume goes to, are set for each display in Displays → Keyboard and sound.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: binding(\.nativeAudioFallback)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adjust the current output when no display can")
                    Text("Its own volume, through macOS, with FreeDisplay’s HUD. When the output has no volume control either, the key goes to macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: binding(\.muteKeyLeftToMacOS)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leave the mute key to macOS")
                    Text("The volume keys stay with FreeDisplay.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Use fine steps by default for volume", isOn: Binding(
                get: { keys.volumeFineByDefault ?? model.settings.adjustmentSteps.fineByDefault },
                set: { value in model.updateNativeKeyPreferences { $0.volumeFineByDefault = value } }))
            if keys.volumeFineByDefault != nil {
                Button("Use shared step default") { model.updateNativeKeyPreferences { $0.volumeFineByDefault = nil } }
            }
            Picker("Feedback sound when a volume key is released", selection: binding(\.volumeFeedbackSound)) {
                Text("As set in macOS").tag(VolumeFeedbackSound.followSystem)
                Text("Always").tag(VolumeFeedbackSound.always)
                Text("Never").tag(VolumeFeedbackSound.never)
            }
            .fixedSize()
            Text(feedbackCaption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Sound Settings…") { Self.openSystemSettings("com.apple.preference.sound") }
                .controlSize(.small)
        }
    }

    private var audioStatusText: String {
        switch model.audioKeyStatus {
        case .off: return ""
        case .disengaged:
            return String(localized: "Right now the volume and mute keys go to macOS: capture is unavailable or no eligible audio route matches the current policies.")
        case .volumeOnly: return String(localized: "Right now FreeDisplay takes the volume keys; the mute key goes to macOS.")
        case .muteOnly: return String(localized: "Right now FreeDisplay takes the mute key; the volume keys go to macOS.")
        case .volumeAndMute: return String(localized: "Right now FreeDisplay takes the volume and mute keys.")
        }
    }

    private var currentOutputText: String {
        guard let output = model.audioSnapshot.currentOutput else {
            return String(localized: "Current sound output: none")
        }
        return String(localized: "Current sound output: \(output.name) (\(KeyboardAndSoundCard.transportName(output.transport)))")
    }

    private var feedbackCaption: String {
        let reading: String
        switch VolumeFeedbackSoundPlayer.systemPreference {
        case .some(true): reading = String(localized: "macOS’s setting is on.")
        case .some(false): reading = String(localized: "macOS’s setting is off.")
        case .none: reading = String(localized: "macOS’s setting wasn’t found, so “As set in macOS” plays nothing.")
        }
        return String(localized: "One sound when the key is released or a volume slider is let go, on the output that changed when that is known. Hold ⇧ (without ⌥) for the opposite. \(reading)")
    }

    private static func openSystemSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
#endif
