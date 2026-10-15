// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// One display's keyboard participation (SD-11) and sound binding (SD-16, TB-08, TR-16): whether the
/// native keys may change it, which macOS output its volume keys follow, and — with native
/// association — which output its volume and mute go to instead of the monitor's own audio.
struct KeyboardAndSoundCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    private var preferences: DisplayKeyboardAudioPreferences {
        model.settings.keyboardAudioPreferences(for: display.recordID)
    }

    private func update(_ change: (inout DisplayKeyboardAudioPreferences) -> Void) {
        model.updateKeyboardAudioPreferences(for: display, change)
    }

    var body: some View {
        ODCard(title: String(localized: "Keyboard and sound"),
               footnote: String(localized: "How the keyboard’s brightness and volume keys treat this display. Sliders, shortcuts and automation aren’t affected, and hiding the display from the menu doesn’t change this.")) {
            ODRow(String(localized: "Brightness and volume keys can change this display")) {
                Toggle("", isOn: Binding(get: { preferences.keyboardControl },
                                         set: { value in update { $0.keyboardControl = value } }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if display.displayClass != .builtIn {
                ODDivider()
                ODRow(String(localized: "Volume goes to"), secondary: routeCaption) {}
                ODDivider()
                ODRow(String(localized: "Use a macOS sound output for this display"),
                      secondary: String(localized: "Volume and mute go to that output instead of the monitor’s own audio. The output macOS plays through doesn’t change.")) {
                    Toggle("", isOn: Binding(get: { preferences.nativeAudioEnabled },
                                             set: { value in update { $0.nativeAudioEnabled = value } }))
                        .toggleStyle(.switch).labelsHidden()
                }
                if preferences.nativeAudioEnabled {
                    ODRow(String(localized: "Sound output")) {
                        outputEditor(text: preferences.nativeAudioDevice,
                                     placeholder: String(localized: "Name or ID")) { value in
                            update { $0.nativeAudioDevice = value }
                        }
                    }
                    caption(resolutionText(model.nativeAudioResolution(for: display),
                                           text: preferences.nativeAudioDevice, binding: true))
                    nativeVolumeRow
                }
                    ODRow(String(localized: "Volume keys follow the output"),
                          secondary: preferences.nativeAudioEnabled
                            ? String(localized: "Empty: follow the associated sound output. An override changes key engagement without changing the volume destination.")
                            : String(localized: "The output that is this display’s. Empty: matched by the display’s own name, over HDMI or DisplayPort only.")) {
                        outputEditor(text: preferences.audioMatch, placeholder: String(localized: "Automatic")) { value in
                            update { $0.audioMatch = value }
                        }
                    }
                    caption(resolutionText(model.audioMatchResolution(for: display),
                                           text: preferences.audioMatch, binding: false))
                ODDivider()
                ODRow(String(localized: "Show the HUD for this display’s volume keys")) {
                    Toggle("", isOn: Binding(get: { preferences.showsVolumeOSD },
                                             set: { value in update { $0.showsVolumeOSD = value } }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .onAppear { model.refreshAudioOutputs() }
    }

    // MARK: - Parts

    /// A text field for an output's name or ID, plus a menu of the outputs connected now (choosing
    /// one enters its unique ID, which no identical device can share).
    private func outputEditor(text: String?, placeholder: String, commit: @escaping (String?) -> Void) -> some View {
        HStack(spacing: 6) {
            CommitTextField(text: text ?? "", placeholder: placeholder) { value in commit(value) }
                .frame(width: 170)
            Button("Copy Current Output") {
                if let output = model.audioSnapshot.currentOutput {
                    commit(NSEvent.modifierFlags.contains(.option) ? output.uid : output.name)
                }
            }
            .disabled(model.audioSnapshot.currentOutput == nil)
            .help(String(localized: "Copy the current output’s name. Hold Option to copy its unique ID."))
            Menu(String(localized: "Choose")) {
                ForEach(model.audioSnapshot.devices) { device in
                    Button(outputMenuTitle(device)) { commit(device.uid) }
                }
                if model.audioSnapshot.devices.isEmpty {
                    Text("No sound outputs found")
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func outputMenuTitle(_ device: AudioOutputDevice) -> String {
        let transport = Self.transportName(device.transport)
        if device.uid == model.audioSnapshot.defaultOutputUID {
            return String(localized: "\(device.name) (\(transport), current output)")
        }
        return String(localized: "\(device.name) (\(transport))")
    }

    /// The bound output's own volume, so the binding can be tried right here.
    @ViewBuilder private var nativeVolumeRow: some View {
        if case .native(let device) = model.audioSink(for: display) {
            ODRow(String(localized: "Output volume")) {
                HStack(spacing: 6) {
                    if device.muteIsToggleable {
                        Button { model.toggleDisplayMute(for: display) } label: {
                            Image(systemName: model.displayIsMuted(for: display) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Mute"))
                    }
                    if let level = device.volumeLevel, device.volume.isSettable {
                    Slider(value: Binding(get: { Double(level) },
                                          set: { model.setDisplayVolume(Float($0), for: display) }),
                           in: 0...1,
                           onEditingChanged: { editing in if !editing { model.volumeSliderReleased(for: display) } })
                        .frame(width: 140)
                    }
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 11).padding(.bottom, 6)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Wording

    /// Where this display's volume goes now — and, when nowhere, why.
    private var routeCaption: String {
        switch model.audioSink(for: display) {
        case .native(let device):
            return String(localized: "“\(device.name)”, a macOS sound output — \(Self.capabilities(device))")
        case .unresolvedNative(let resolution):
            switch resolution {
            case .ambiguous:
                return String(localized: "Nowhere: several outputs fit the name below. Choose one from the list.")
            case .missing:
                return String(localized: "Nowhere: the chosen output isn’t connected. Volume and mute of this display do nothing until it is.")
            case .unset, .matched:
                return String(localized: "Nowhere yet: choose an output below.")
            }
        case .hardware:
            #if PUBLIC_API_ONLY
            return String(localized: "This build can’t reach the monitor’s own audio. Choose a macOS sound output instead.")
            #else
            return model.ddcControl(.volume, for: display) != nil
                ? String(localized: "The monitor’s own audio, over DDC")
                : String(localized: "The monitor’s own audio, over DDC — not confirmed yet, so the volume keys go to macOS")
            #endif
        case .none:
            return String(localized: "Nowhere")
        }
    }

    private func resolutionText(_ resolution: AudioDeviceResolution, text: String?, binding: Bool) -> String {
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch resolution {
        case .unset:
            if binding { return String(localized: "Choose an output.") }
            if preferences.nativeAudioEnabled {
                return String(localized: "Automatic: follow the associated sound output.")
            }
            return String(localized: "Automatic: the volume keys take this display when the current output carries its name.")
        case .matched(let device):
            return binding
                ? String(localized: "Found “\(device.name)” (\(Self.transportName(device.transport))): \(Self.capabilities(device)).")
                : String(localized: "Found “\(device.name)” (\(Self.transportName(device.transport))). The volume keys take this display while it is the current output.")
        case .ambiguous(let devices):
            return String(localized: "\(devices.count) outputs fit “\(typed)”, so none is used. Choose one from the list: that enters its unique ID.")
        case .missing:
            return binding
                ? String(localized: "No connected output is named “\(typed)”. Enter its exact name or ID.")
                : String(localized: "No connected output fits “\(typed)”, so the volume keys don’t take this display.")
        }
    }

    private static func capabilities(_ device: AudioOutputDevice) -> String {
        switch (device.volumeIsAdjustable, device.muteIsToggleable) {
        case (true, true): return String(localized: "volume and mute")
        case (true, false): return String(localized: "volume only, no mute")
        case (false, true): return String(localized: "mute only, no adjustable volume")
        case (false, false): return String(localized: "no adjustable volume or mute")
        }
    }

    static func transportName(_ transport: AudioOutputTransport) -> String {
        switch transport {
        case .hdmi: return String(localized: "HDMI")
        case .displayPort: return String(localized: "DisplayPort")
        case .builtIn: return String(localized: "built-in")
        case .usb: return String(localized: "USB")
        case .bluetooth: return String(localized: "Bluetooth")
        case .aggregate: return String(localized: "multi-output")
        case .virtual: return String(localized: "virtual")
        case .airPlay: return String(localized: "AirPlay")
        case .other: return String(localized: "other")
        }
    }
}

/// A single-line text field that saves on Return, Tab or leaving it (and when the page goes away
/// mid-edit), and puts the saved text back on Esc — the AppKit delegate sees Esc, which a SwiftUI
/// `TextField` doesn't pass on. Blank text saves as nil.
struct CommitTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let commit: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        // Never overwrite what is being typed; show the saved value otherwise.
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        if field.currentEditor() != nil { coordinator.save(field.stringValue) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommitTextField
        private var reverting = false

        init(_ parent: CommitTextField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            reverting = true
            textView.string = parent.text
            control.window?.makeFirstResponder(nil)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if reverting {
                reverting = false
                field.stringValue = parent.text
                return
            }
            save(field.stringValue)
        }

        func save(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let new: String? = trimmed.isEmpty ? nil : trimmed
            let old: String? = parent.text.isEmpty ? nil : parent.text
            if new != old { parent.commit(new) }
        }
    }
}
#endif
