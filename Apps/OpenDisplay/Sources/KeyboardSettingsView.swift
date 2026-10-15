// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

extension HotkeyAction {
    /// The action's name as Settings shows it.
    var localizedTitle: String {
        switch self {
        case .reconnectAll: return String(localized: "Reconnect All Displays")
        case .cycleMainDisplay: return String(localized: "Make the Next Display Main")
        case .brightnessUp: return String(localized: "Brightness Up")
        case .brightnessDown: return String(localized: "Brightness Down")
        case .brightnessUpFine: return String(localized: "Brightness Up (Fine Step)")
        case .brightnessDownFine: return String(localized: "Brightness Down (Fine Step)")
        case .faceLight: return String(localized: "Toggle FaceLight")
        case .toggleMenu: return String(localized: "Show or Hide the FreeDisplay Menu")
        case .openSettings: return String(localized: "Open FreeDisplay Settings")
        case .quit: return String(localized: "Quit FreeDisplay")
        case .toggleConsole: return String(localized: "Show or Hide the Console")
        case .restart: return String(localized: "Restart FreeDisplay")
        case .softwareContrastUp: return String(localized: "Software Contrast Up")
        case .softwareContrastDown: return String(localized: "Software Contrast Down")
        case .softwareContrastUpFine: return String(localized: "Software Contrast Up (Fine)")
        case .softwareContrastDownFine: return String(localized: "Software Contrast Down (Fine)")
        case .warmer: return String(localized: "Warmer")
        case .cooler: return String(localized: "Cooler")
        case .resetSoftwareAdjustments: return String(localized: "Reset Software Adjustments")
        case .toggleSoftwareAdjustments: return String(localized: "Suspend or Resume Software Adjustments")
        case .volumeUp: return String(localized: "CoreAudio Volume Up")
        case .volumeDown: return String(localized: "CoreAudio Volume Down")
        case .volumeUpFine: return String(localized: "CoreAudio Volume Up (Fine)")
        case .volumeDownFine: return String(localized: "CoreAudio Volume Down (Fine)")
        case .toggleMute: return String(localized: "Toggle CoreAudio Mute")
        case .mute: return String(localized: "Mute CoreAudio Output")
        case .unmute: return String(localized: "Unmute CoreAudio Output")
        }
    }
}

/// Settings → Keyboard: the native brightness/volume keys (SO-25–SO-28), the global shortcut recorder
/// (SO-30, with the app actions of SO-38), the shared adjustment steps (SO-29) and the input hotkeys.
struct KeyboardSettingsSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ODSpacing.md) {
                NativeKeyboardControlCard()  // SO-25–SO-28 (NativeKeyboardSettingsView.swift)
                Divider()
                KeyboardShortcutsCard()
                Divider()
                AdjustmentStepsCard()
                Divider()
                InputHotkeySection()
            }
            .padding(ODSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Keyboard")
    }
}

// MARK: - Shortcut recorder (SO-30)

private struct KeyboardShortcutsCard: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var recorder = ShortcutRecorder()

    /// Settings' grouping of the actions. Every `HotkeyAction` appears exactly once.
    private static let groups: [(title: LocalizedStringKey, actions: [HotkeyAction])] = [
        ("Recovery", [.reconnectAll]),
        ("Displays", [.cycleMainDisplay, .faceLight]),
        ("Brightness", [.brightnessUp, .brightnessDown, .brightnessUpFine, .brightnessDownFine]),
        ("Software image adjustments", [.softwareContrastUp, .softwareContrastDown, .softwareContrastUpFine,
                                         .softwareContrastDownFine, .warmer, .cooler,
                                         .resetSoftwareAdjustments, .toggleSoftwareAdjustments]),
        ("CoreAudio", [.volumeUp, .volumeDown, .volumeUpFine, .volumeDownFine, .toggleMute, .mute, .unmute]),
        ("FreeDisplay", [.toggleMenu, .toggleConsole, .openSettings, .quit, .restart]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            Text("Keyboard shortcuts").font(.title3)
            Text("These shortcuts work in every app while FreeDisplay is running. Click a shortcut, then press the new keys: a function key, or a key together with ⌘, ⌥ or ⌃. Esc cancels; Delete removes the shortcut. Shortcuts are paused while you record one. A registered shortcut can still be taken first by macOS or by another app that uses the same keys.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Image adjustments use the brightness-key targets and keep brightness active when suspended. CoreAudio shortcuts use the configured audio targets and native fallback; DDC-only targets are unavailable. Hold a level shortcut to repeat; volume feedback plays once on release. Quit and Restart act immediately. Gamma exponent, inversion and HDR boost shortcuts are unavailable.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Self.groups.indices, id: \.self) { index in
                let group = Self.groups[index]
                Text(group.title).font(.headline).padding(.top, ODSpacing.xs)
                ForEach(group.actions, id: \.self) { action in
                    ShortcutRow(action: action, recorder: recorder)
                }
            }
            HStack {
                Text("Reconnect All stays in the menu without a shortcut. Shortcuts made in the Shortcuts app get their keys there, in each shortcut’s details.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore All Defaults") {
                    recorder.cancel()
                    model.restoreDefaultHotkeys()
                }
            }
            .padding(.top, ODSpacing.xs)
        }
        .onAppear { recorder.model = model }
        .onDisappear { recorder.cancel() }
    }
}

/// One action: its name, whether its shortcut is live, and the recorder / remove / restore controls.
private struct ShortcutRow: View {
    @EnvironmentObject private var model: AppModel
    let action: HotkeyAction
    @ObservedObject var recorder: ShortcutRecorder

    private var binding: KeyBinding? { model.effectiveHotkeyRegistry.binding(for: action) }
    private var isRecording: Bool { recorder.action == action }

    var body: some View {
        HStack(alignment: .center, spacing: ODSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.localizedTitle)
                statusLine.font(.caption)
                if isRecording, let feedback = recorder.feedback {
                    Text(feedback).font(.caption).foregroundStyle(ODColor.danger)
                } else if let binding, HotkeyRecorderPolicy.mayShadowAppMenus(binding) {
                    Text("Apps use shortcuts like this in their menus; they won’t receive it while FreeDisplay runs.")
                        .font(.caption).foregroundStyle(ODColor.caution)
                }
                if let binding { SystemShortcutNotice(binding: binding) }  // SO-30: keys macOS keeps
                if action == .quit, binding != nil {
                    Text("Quits at once, without asking. Choose keys you won’t press by accident.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                recorder.toggle(action)
            } label: {
                Text(recorderTitle)
                    .monospacedDigit()
                    .frame(minWidth: 120)
            }
            .background(RecorderAnchor(recorder: recorder, action: action))
            .accessibilityLabel(Text(action.localizedTitle))
            .accessibilityValue(Text(recorderTitle))
            .accessibilityHint(Text("Records a new shortcut"))
            Button {
                recorder.cancel()
                model.setHotkeyBinding(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove Shortcut")
            .accessibilityLabel(Text("Remove Shortcut"))
            .disabled(binding == nil)
            Button {
                recorder.cancel()
                model.restoreDefaultHotkey(for: action)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderless)
            .help(restoreHelp)
            .accessibilityLabel(Text("Restore Default"))
            .disabled(binding == action.defaultBinding || defaultHolder != nil)
        }
        .padding(.vertical, 2)
    }

    /// The slot that now holds this action's shipped chord, if another one does.
    private var defaultHolder: HotkeySlot? {
        action.defaultBinding.flatMap { model.hotkeySlot(using: $0, excluding: action) }
    }

    private var restoreHelp: String {
        guard let shipped = action.defaultBinding else { return String(localized: "Restore Default (no shortcut)") }
        let chord = KeyBindingFormatter.string(for: shipped)
        if let holder = defaultHolder {
            return String(localized: "The standard shortcut \(chord) is used by \(model.hotkeySlotName(holder)).")
        }
        return String(localized: "Restore Default (\(chord))")
    }

    private var recorderTitle: String {
        if isRecording { return String(localized: "Type Shortcut…") }
        return binding.map(KeyBindingFormatter.string(for:)) ?? String(localized: "Record Shortcut")
    }

    @ViewBuilder private var statusLine: some View {
        switch model.hotkeyStatus[action] ?? .unassigned {
        case .registered:
            Label("Registered", systemImage: "checkmark.circle.fill")
                .foregroundStyle(ODColor.connected)
        case .unassigned:
            Text("No shortcut").foregroundStyle(.secondary)
        case .cleared:
            if action.defaultBinding != nil {
                Text("Off — the standard shortcut was removed").foregroundStyle(.secondary)
            } else {
                Text("No shortcut").foregroundStyle(.secondary)
            }
        case .conflict(let holder):
            Label("Not registered: \(model.hotkeySlotName(holder)) uses the same shortcut",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ODColor.caution)
        case .failed:
            Label("Not registered: macOS refused this shortcut; another app may already use it",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ODColor.caution)
        case .paused:
            Text("Paused while a shortcut is recorded").foregroundStyle(.secondary)
        }
    }
}

/// Records one shortcut at a time (SO-30). While recording, every global chord is unregistered
/// (`AppModel.pauseHotkeys`) so the keys typed here can't fire an action, and recording ends on
/// Esc, Tab, a click anywhere but the recorder itself, the window losing focus, OpenDisplay going
/// to the background, or the page closing.
@MainActor
final class ShortcutRecorder: ObservableObject {
    /// The action being recorded, or nil.
    @Published private(set) var action: HotkeyAction?
    /// Why the last key wasn't taken, shown under the row being recorded.
    @Published private(set) var feedback: String?
    weak var model: AppModel?

    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var anchors: [HotkeyAction: WeakView] = [:]

    private struct WeakView { weak var view: NSView? }

    func toggle(_ action: HotkeyAction) {
        if self.action == action { cancel() } else { begin(action) }
    }

    func begin(_ action: HotkeyAction) {
        guard let model else { return }
        if self.action == nil { installMonitors() }
        self.action = action
        feedback = nil
        model.pauseHotkeys()
    }

    /// Ends recording without changing anything.
    func cancel() {
        guard action != nil else { return }
        stopRecording()
        model?.resumeHotkeys()
    }

    fileprivate func register(_ view: NSView, for action: HotkeyAction) {
        anchors[action] = WeakView(view: view)
    }

    private func stopRecording() {
        action = nil
        feedback = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func installMonitors() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }) { monitors.append(keys) }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                // A click on the recorder itself is the recorder's own toggle; anything else ends it.
                if let self, !self.isOnRecorder(event) { self.cancel() }
            }
            return event
        }) { monitors.append(clicks) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                            queue: .main) { [weak self] notification in
            // Only the window's identity crosses into the main-actor block; the notification stays here.
            let resigned = (notification.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let action = self.action,
                      let window = self.anchors[action]?.view?.window,
                      resigned == ObjectIdentifier(window) else { return }
                self.cancel()
            }
        })
    }

    private func isOnRecorder(_ event: NSEvent) -> Bool {
        guard let action, let view = anchors[action]?.view, let window = view.window,
              event.window === window else { return false }
        return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }

    /// Acts on one key press while recording; true when the press was the recorder's (and must not
    /// reach the window).
    private func handle(_ event: NSEvent) -> Bool {
        guard let action, let model else { return false }
        let verdict = HotkeyRecorderPolicy.verdict(keyCode: UInt32(event.keyCode),
                                                   modifiers: Self.carbonModifiers(event.modifierFlags))
        switch verdict {
        case .cancel:
            cancel()
            return true
        case .endAndPassThrough:
            cancel()
            return false
        case .clear:
            stopRecording()
            model.setHotkeyBinding(nil, for: action)
            model.resumeHotkeys()
            return true
        case .reject:
            NSSound.beep()
            feedback = String(localized: "Use a function key, or hold ⌘, ⌥ or ⌃ with the key.")
            return true
        case .accept(let binding):
            // One chord, one action: a duplicate would leave one of the two silently dead. The
            // recovery chord is refused outright (owner decision #26).
            if let refusal = model.hotkeyRefusal(for: binding, action: action) {
                NSSound.beep()
                feedback = refusal
                return true
            }
            stopRecording()
            model.setHotkeyBinding(binding, for: action)
            model.resumeHotkeys()
            return true
        }
    }

    /// AppKit's modifier flags as the Carbon mask a `KeyBinding` stores.
    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= KeyBinding.command }
        if flags.contains(.shift) { mask |= KeyBinding.shift }
        if flags.contains(.option) { mask |= KeyBinding.option }
        if flags.contains(.control) { mask |= KeyBinding.control }
        return mask
    }
}

/// An invisible view behind a recorder button, so the recorder can tell a click on its own button
/// (its toggle) from a click anywhere else (which ends recording).
private struct RecorderAnchor: NSViewRepresentable {
    let recorder: ShortcutRecorder
    let action: HotkeyAction

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        recorder.register(view, for: action)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        recorder.register(view, for: action)
    }
}

// MARK: - Adjustment steps (SO-29)

private struct AdjustmentStepsCard: View {
    @EnvironmentObject private var model: AppModel

    private var steps: AdjustmentSteps { model.settings.adjustmentSteps }

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            Text("Adjustment steps").font(.title3)
            Text("How far one press of a brightness or volume key, or a level shortcut, moves the level. Leave a field empty for its default.")
                .font(.caption).foregroundStyle(.secondary)
            StepField(title: "Steps across the full range", defaultValue: AdjustmentSteps.defaultRange,
                      stored: steps.range) { value in update { $0.range = value } }
            StepField(title: "Standard step", defaultValue: AdjustmentSteps.defaultStandard,
                      stored: steps.standard) { value in update { $0.standard = value } }
            StepField(title: "Fine step", defaultValue: AdjustmentSteps.defaultFine,
                      stored: steps.fine) { value in update { $0.fine = value } }
            Toggle("Brightness and volume keys take fine steps", isOn: Binding(
                get: { steps.fineByDefault }, set: { value in update { $0.fineByDefault = value } }))
            Text("One standard step is \(Self.percentText(steps.fraction(fine: false))) % of the range; one fine step is \(Self.percentText(steps.fraction(fine: true))) %. Hold ⇧⌥ with a brightness or volume key for the other step. The fine-step shortcuts always take fine steps. A monitor with fewer levels of its own may round a step.")
                .font(.caption).foregroundStyle(.secondary)
            if [steps.range, steps.standard, steps.fine].contains(where: { ($0 ?? 1) < 1 }) {
                Text("A value below 1 isn’t used; its default applies instead.")
                    .font(.caption).foregroundStyle(ODColor.caution)
            }
        }
    }

    private func update(_ change: (inout AdjustmentSteps) -> Void) {
        var updated = steps
        change(&updated)
        model.setAdjustmentSteps(updated)
    }

    private static func percentText(_ fraction: Float) -> String {
        Double(fraction * 100).formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// One numeric field. Return, Tab or leaving the field saves it, Esc puts the saved value back, and
/// an empty or non-numeric entry means "use the default".
private struct StepField: View {
    let title: LocalizedStringKey
    let defaultValue: Int
    let stored: Int?
    let commit: (Int?) -> Void

    var body: some View {
        LabeledContent(title) {
            StepTextField(placeholder: String(defaultValue), stored: stored, commit: commit)
                .frame(width: 80)
        }
    }
}

/// The AppKit field behind `StepField`. Its delegate sees Esc (`cancelOperation:`), which a SwiftUI
/// `TextField` doesn't pass on, and every way editing ends: Return, Tab, a click elsewhere, the page
/// going away.
private struct StepTextField: NSViewRepresentable {
    let placeholder: String
    let stored: Int?
    let commit: (Int?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: Self.text(for: stored))
        field.placeholderString = placeholder
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Never overwrite what is being typed; show the saved value otherwise.
        if field.currentEditor() == nil { field.stringValue = Self.text(for: stored) }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        // Leaving the page while typing saves, like leaving the field.
        if field.currentEditor() != nil { coordinator.save(field.stringValue) }
    }

    static func text(for value: Int?) -> String { value.map(String.init) ?? "" }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: StepTextField
        private var reverting = false

        init(_ parent: StepTextField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            reverting = true
            textView.string = StepTextField.text(for: parent.stored)
            control.window?.makeFirstResponder(nil)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if reverting {
                reverting = false
                field.stringValue = StepTextField.text(for: parent.stored)
                return
            }
            save(field.stringValue)
            field.stringValue = StepTextField.text(for: AdjustmentSteps.parse(field.stringValue))
        }

        func save(_ text: String) {
            let parsed = AdjustmentSteps.parse(text)
            if parsed != parent.stored { parent.commit(parsed) }
        }
    }
}
#endif
