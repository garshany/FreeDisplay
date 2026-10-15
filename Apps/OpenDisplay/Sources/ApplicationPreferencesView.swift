#if os(macOS)
import AppKit
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// SO-10/SD-08/FB-12: app preferences and assertion ownership, without device writes in the view.
struct ApplicationPreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var placement = SettingsWindowMemory.placement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ODSpacing.md) {
                ODCard(title: String(localized: "Startup and windows"), padded: true) {
                    LaunchAtLoginToggle()
                    Picker("Open Settings", selection: $placement) {
                        Text("At its last position").tag(SettingsWindowPlacement.lastPosition)
                        Text("On the pointer’s screen").tag(SettingsWindowPlacement.pointerScreen)
                    }
                    .onChange(of: placement) { _, value in SettingsWindowMemory.placement = value }
                    DockIconPolicyRow()
                    Toggle(isOn: Binding(
                        get: { model.settings.autoDisconnectBuiltInOnExternal },
                        set: { model.setAutoDisconnectBuiltInOnExternal($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Turn the built-in display off when an external connects")
                            Text("When an external display arrives, the built-in panel is turned off automatically (through the same safety-checked path as a manual disconnect). It comes back on when the last external is unplugged.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ApplicationTimingCard()
                DisplaySleepPreventionCard()
                ODCard(title: String(localized: "Updates"), padded: true) { ApplicationUpdatePreferences() }
                ODCard(title: String(localized: "Event notices"), padded: true) { NotificationSettingsRows() }
                ODCard(title: String(localized: "Privacy"), padded: true) {
                    Text("FreeDisplay has no automatic analytics or crash uploader. Preferences and diagnostic logs stay on this Mac unless you export and share them. macOS diagnostics are managed separately by Apple.")
                    Text("Optional features may use the network: signed update checks when enabled in a validated release, configured network-display controllers, the local HTTP server, and links you open. Location is requested only when you choose it for Clock Mode; coordinates can also be entered manually.")
                    Link("Read the privacy policy", destination: ProjectIdentity.link(.privacy).url)
                }
            }
            .padding(ODSpacing.lg)
        }
        .navigationTitle("Application")
    }
}

private struct ApplicationTimingCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ODCard(title: String(localized: "Timing and motion"), padded: true) {
            TimingPreferenceRow(title: String(localized: "Configuration delay (seconds)"),
                                value: binding(\.configurationDelay))
            TimingPreferenceRow(title: String(localized: "Wake delay (seconds)"), value: binding(\.wakeDelay))
            TimingPreferenceRow(title: String(localized: "Animation duration (seconds)"),
                                value: binding(\.animationDuration))
            Text("Blank keeps the existing behavior: no added configuration or wake delay, and the current menu animation duration. Zero explicitly disables that delay or animation. Negative, nonnumeric or unschedulable values are rejected; there is no product maximum configured.")
            Text("Delays postpone automatic built-in disconnection, managed-offline reassertion and protected-layout restoration. Emergency screen recovery never waits. Menu animations also stop when Animate the menu is off or macOS Reduce Motion is on.")
        }
        .font(.callout)
    }

    private func binding(_ key: WritableKeyPath<ApplicationTimingPreferences, TimingValue>) -> Binding<TimingValue> {
        Binding(get: { model.settings.applicationTiming[keyPath: key] }, set: { value in
            var timing = model.settings.applicationTiming
            timing[keyPath: key] = value
            model.setApplicationTiming(timing)
        })
    }
}

/// Edit a draft first; invalid input never replaces the saved preference.
private struct TimingPreferenceRow: View {
    let title: String
    @Binding var value: TimingValue
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                TextField("Automatic", text: $draft)
                    .frame(width: 110)
                    .onSubmit { apply() }
                    .accessibilityLabel(title)
                Button("Apply") { apply() }
                Button("Default") { value = .automatic; draft = ""; error = nil }
            }
            if let error { Text(error).font(.caption).foregroundStyle(ODColor.danger) }
        }
        .onAppear { draft = value.fieldText }
        .onChange(of: value) { _, new in draft = new.fieldText }
    }

    private func apply() {
        switch ApplicationTiming.parse(draft) {
        case .accepted(let parsed): value = parsed; draft = parsed.fieldText; error = nil
        case .rejected(.notANumber): error = String(localized: "Enter a finite number of seconds, or leave blank for automatic.")
        case .rejected(.negative): error = String(localized: "Seconds cannot be negative. The saved value was kept.")
        case .rejected(.tooLargeToSchedule): error = String(localized: "This duration cannot be represented by the scheduler. The saved value was kept.")
        case .rejected(.aboveMaximum): error = String(localized: "This exceeds the configured maximum. The saved value was kept.")
        }
    }
}

struct DisplaySleepPreventionCard: View {
    @EnvironmentObject private var model: AppModel

    private var displayIDs: [DisplayRecordID] {
        Array(Set(model.displays.map(\.recordID)).union(
            model.settings.preventDisplaySleepDisplayIDs.map(DisplayRecordID.init(rawValue:))))
            .sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        ODCard(title: String(localized: "Idle display sleep"), padded: true) {
            Toggle("Keep displays awake while an external is connected", isOn: Binding(
                get: { model.settings.preventDisplaySleepWithExternal },
                set: { model.setPreventDisplaySleepWithExternal($0) }))
            Text("Prevents idle display sleep only. It does not prevent system sleep, lid sleep or Sleep chosen by the user. Other apps can hold their own assertions independently.")
            ForEach(displayIDs, id: \.self) { id in
                let live = model.displays.first { $0.recordID == id }
                Toggle(isOn: Binding(get: { model.preventsDisplaySleep(id) },
                                     set: { model.setPreventsDisplaySleep($0, for: id) })) {
                    VStack(alignment: .leading) {
                        Text(model.rememberedDisplayName(for: id))
                        Text("Keep displays awake while this display is connected")
                            .font(.caption).foregroundStyle(.secondary)
                        if !model.canPersistDisplaySettings(id) {
                            Text("A verified persistent display identity is required. Earlier provisional associations remain saved but inactive.").font(.caption)
                        } else if live == nil {
                            Text("Not connected; no assertion is held for this display.").font(.caption)
                        } else if let live, DisplaySleepPrevention.ineligibility(of: .init(live)) == .unverified {
                            Text("Physical display presence is unverified; this display cannot own the assertion.").font(.caption)
                        }
                    }
                }
                .disabled(!model.canPersistDisplaySettings(id) || (!model.preventsDisplaySleep(id) &&
                          (live.map { DisplaySleepPrevention.ineligibility(of: .init($0)) != nil } ?? true)))
            }
            Text("Only active displays with verified physical presence can own the assertion. Turning off one display’s preference leaves other owners and the global external-display preference unchanged.")
            LabeledContent("Assertion type", value: DisplaySleepPrevention.assertionType).textSelection(.enabled)
            Text(assertionStatus).textSelection(.enabled)
            if !model.displaySleepPrevention.decision.owners.isEmpty {
                Text("Requested by: \(model.displaySleepPrevention.decision.owners.map { model.rememberedDisplayName(for: $0) }.joined(separator: ", "))")
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    private var assertionStatus: String {
        switch model.displaySleepPrevention.status {
        case .released: return String(localized: "FreeDisplay holds no display-sleep assertion.")
        case .held(let id): return String(localized: "FreeDisplay assertion ID: \(id). This is not a process ID.")
        case .refused: return String(localized: "macOS refused FreeDisplay’s display-sleep assertion. The displays are not kept awake by FreeDisplay.")
        }
    }
}

struct ApplicationUpdatePreferences: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let refusal = model.updateDistributionRefusal {
            Text(SoftwareUpdater.refusalExplanation(refusal))
            Link("FreeDisplay releases", destination: ProjectIdentity.link(.releases).url)
        }
        if model.checksGitHubReleases || model.updateDistributionRefusal == nil {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { model.settings.updateCheckEnabled }, set: { model.setUpdateCheckEnabled($0) }))
            if !model.checksGitHubReleases {
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { model.settings.automaticUpdateDownloadEnabled },
                    set: { model.setAutomaticUpdateDownloadEnabled($0) }))
                    .disabled(!model.settings.updateCheckEnabled)
            }
            Button("Check Now in About…") {
                NotificationCenter.default.post(name: Notification.Name("OpenDisplayShowSection"), object: "about")
                model.checkForUpdates()
            }
        }
    }
}
#endif
