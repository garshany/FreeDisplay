#if os(macOS)
import AutomationSchema
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// The per-display detail pane (Settings → Displays). This is where everything that used to crowd the
/// menu-bar card now lives: resolution & refresh, appearance (rotation/colour), hardware controls,
/// input, "use as", identity, and read-only info — grouped into System-Settings-style cards. The menu
/// bar deep-links here via "Display settings…". See `Docs/InterfaceRedesign.md`.
struct DisplayDetailView: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let pending = model.pendingRevert {
                    // Timed auto-revert prompt for a change made here in Settings (Issue 6).
                    VStack(alignment: .leading, spacing: 6) {
                        ODInlineBanner(tone: .orange, systemImage: "clock.arrow.circlepath",
                                       title: String(localized: "Keep these display settings?"),
                                       message: String(localized: "\(pending.message). Reverting in \(pending.secondsRemaining)s…"))
                        HStack(spacing: 8) {
                            Button("Keep") { model.confirmArrangementChange() }
                                .keyboardShortcut(.defaultAction)
                            Button("Revert Now") { Task { await model.revertArrangementChange() } }
                            Spacer()
                        }
                    }
                }
                ResolutionCard(display: display)
                AppearanceCard(display: display)
                ColorProfileCard(display: display)
                if display.displayClass != .builtIn { ControlsCard(display: display) }
                DimmingCard(display: display)
                UseAsCard(display: display)
                IdentityCard(display: display)
                InformationCard(display: display)
                // Display-agnostic, but the Displays tab is where it belongs (Issue #39) and this is
                // the tab's only scrolling surface.
                DisplayGroupsCard()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: display.recordID) {
            // Opening the detail pane is a deliberate act — if this display currently has NO working
            // hardware control, retry even negatively-cached DDC features so a monitor that just
            // recovered (power-cycle, input switch) shows its controls now. Healthy displays keep
            // their probe cache, so reopening the pane stays fast.
            model.retryDDCDiscoveryIfDead(for: display)
            await model.refreshBrightness(for: display)
            await model.refreshColorProfile(for: display)
            if display.displayClass != .builtIn {
                await model.refreshHardwareControls(for: display)
                await model.refreshColorPreset(for: display)
                await model.refreshInputSource(for: display)
            }
        }
    }
}

// MARK: - Resolution

struct ResolutionCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    let compact: Bool

    init(display: DisplayObservation, compact: Bool = false) {
        self.display = display
        self.compact = compact
    }
    @State private var allModes: [DisplayMode] = []
    @State private var selectedMode: DisplayMode?
    @State private var applying = false
    @State private var showLowerDensity = false

    private var choices: [DisplayMode] {
        DisplayModeChoices.visible(from: allModes, current: display.mode, includeLowerDensity: showLowerDensity)
    }

    private var canApply: Bool {
        !applying && model.pendingRevert == nil && !model.arrangementApplying && display.isActive
            && DisplayModeChoices.canApply(selectedMode, current: display.mode, choices: choices)
    }

    var body: some View {
        ODCard(title: compact ? nil : String(localized: "Resolution and scaling"),
               footnote: compact ? String(localized: "A mode is applied only when you click Apply.") : String(localized: "Logical size sets the workspace. The framebuffer is the size of the image macOS renders; it doesn’t report the panel’s physical resolution. A large HiDPI framebuffer may be scaled again and doesn’t guarantee sharper output on every monitor. A selection takes effect only after you click Apply, and it must be confirmed.")) {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current mode").font(.system(size: 11)).foregroundStyle(.secondary)
                    currentModeText
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Choose mode").font(.system(size: 11)).foregroundStyle(.secondary)
                    modePicker.frame(maxWidth: .infinity)
                }.padding(10)
            } else {
                ODRow(String(localized: "Current mode")) {
                    currentModeText.multilineTextAlignment(.trailing)
                        .frame(maxWidth: 380, alignment: .trailing)
                }
                ODDivider()
                ODRow(String(localized: "Choose mode")) { modePicker.frame(maxWidth: 380) }
            }
            ODDivider()
            ODRow(String(localized: "More modes")) {
                Toggle(compact ? "Show non-HiDPI" : "Show non-HiDPI alternatives", isOn: $showLowerDensity)
                    .font(.system(size: 11)).disabled(applying || model.pendingRevert != nil)
                    .help("Non-HiDPI variants are hidden by default when a HiDPI mode exists for the same logical size. The current mode always stays visible.")
            }
            if let error = model.modeChangeError {
                ODDivider()
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    .textSelection(.enabled).padding(10)
            }
            if let selectedMode, selectedMode != display.mode {
                ODDivider()
                if compact {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Will apply").foregroundStyle(.secondary)
                        Text(AppModel.modeLabel(selectedMode))
                    }
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                } else {
                    ODRow(String(localized: "Will apply")) {
                        Text(AppModel.modeLabel(selectedMode))
                            .font(.system(size: 11)).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 380, alignment: .trailing)
                    }
                }
            }
            if !compact, let current = display.mode {
                ODDivider()
                ODRow(String(localized: "Favourite modes")) {
                    HStack(spacing: 8) {
                        Button { model.toggleFavoriteResolution(current, for: display) } label: {
                            Image(systemName: model.isFavoriteResolution(current, for: display) ? "star.fill" : "star")
                        }
                        .buttonStyle(.plain)
                        .help("Add the current mode to favourites or remove it")
                        Menu("Choose from Favourites") {
                            ForEach(model.favoriteResolutions(among: choices, for: display), id: \.self) { favorite in
                                Button(AppModel.modeLabel(favorite)) { selectedMode = favorite }
                            }
                        }
                        .disabled(model.favoriteResolutions(among: choices, for: display).isEmpty
                                  || applying || model.pendingRevert != nil)
                    }
                }
            }
            ODDivider()
            if compact {
                actionButtons.frame(maxWidth: .infinity, alignment: .trailing).padding(10)
            } else {
                ODRow(String(localized: "Change mode")) { actionButtons }
            }
        }
        .task(id: display.cgDisplayID) {
            allModes = model.allModes(for: display)
            selectedMode = display.mode
        }
        .onChange(of: showLowerDensity) { _, _ in
            if let selectedMode, !choices.contains(selectedMode) { self.selectedMode = display.mode }
        }
        .onChange(of: display.mode) { _, current in
            // Restore/readback only updates the draft; observing a mode never writes a mode.
            selectedMode = current
            allModes = model.allModes(for: display)
        }
    }

    private var currentModeText: some View {
        Text(display.mode.map { AppModel.modeLabel($0) }
             ?? String(localized: "macOS didn’t report the current mode"))
            .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
    }

    @ViewBuilder private var modePicker: some View {
        if choices.isEmpty {
            Text("No modes available").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Picker("New display mode", selection: $selectedMode) {
                if selectedMode == nil { Text("Choose a mode").tag(nil as DisplayMode?) }
                ForEach(choices, id: \.self) { mode in
                    Text(AppModel.modeLabel(mode)).tag(Optional(mode))
                }
            }
            .labelsHidden().pickerStyle(.menu)
            .disabled(applying || model.pendingRevert != nil)
            .help("Full mode: logical size, framebuffer, refresh rate and HiDPI")
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("Reset Selection") { selectedMode = display.mode }
                .disabled(applying || selectedMode == display.mode)
            Button("Apply") { applySelection() }.disabled(!canApply)
            if applying { ProgressView().controlSize(.small) }
        }
    }

    private func applySelection() {
        guard canApply, let target = selectedMode else { return }
        applying = true
        Task { @MainActor in
            defer { applying = false }
            // AppModel checkpoints this exact mode change and auto-reverts until confirmed.
            await model.setMode(target, for: display)
        }
    }
}

// MARK: - Appearance (rotation + colour)

struct AppearanceCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var detectingModes = false
    /// Set when an explicit "Detect…" came back empty; cleared after a few seconds so a transient
    /// failure doesn't sit on the card as if it were a permanent property of the monitor.
    @State private var detectFoundNothing = false

    /// Displayed kelvin for the temperature slider (absent cache = neutral).
    private var temperature: Float {
        model.colorTemperature[display.recordID] ?? ColorTemperatureCurve.neutralKelvin
    }

    var body: some View {
        ODCard(title: String(localized: "Appearance")) {
            ODRow(String(localized: "Colour temperature")) {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.sun").font(.system(size: 11)).foregroundStyle(.orange)
                    Slider(value: Binding(get: { Double(temperature) },
                                          set: { model.setColorTemperature(Float($0), for: display) }),
                           in: Double(ColorTemperatureCurve.minKelvin)...Double(ColorTemperatureCurve.maxKelvin))
                        .frame(width: 140)
                    Image(systemName: "thermometer.snowflake").font(.system(size: 11)).foregroundStyle(.cyan)
                    Text(model.colorTemperature[display.recordID] == nil
                         ? "Native" : "\(Int(temperature)) K")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()  // «Системный» is wider than "6500 K"; never wrap it
                        .frame(minWidth: 48, alignment: .trailing)
                }
            }
            ODDivider()
            ODRow(String(localized: "Rotation")) {
                if model.rotationWritable {
                    HStack(spacing: 6) {
                        ODBadge(String(localized: "Experimental"), tone: .orange)
                        Menu("\(model.currentRotation(for: display))°") {
                            ForEach([0, 90, 180, 270], id: \.self) { deg in
                                Button("\(deg)°") { Task { await model.setRotation(deg, for: display) } }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                    }
                } else {
                    Text("\(model.currentRotation(for: display))°").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            // DDC writes only — the public-API-only build has no body for `setColorPreset` (SD-03), and
            // its Controls card says DDC isn't available there.
            #if !PUBLIC_API_ONLY
            if display.displayClass != .builtIn {
                ODDivider()
                // TR-07: this is the MONITOR's own picture preset (VCP 0x14: sRGB, 6500K, User…), not
                // the connection's colour format (RGB/YCbCr, range, depth) nor an ICC profile.
                ODRow(String(localized: "Monitor colour preset")) {
                    // Offer only the preset codes the panel advertises (VCP 0x14 is a non-continuous
                    // enum); a contiguous 1...max guess offers codes the monitor silently ignores.
                    // NOTE: capabilities are only populated by an explicit read (the 0xF3 read can
                    // wedge panels, so the app never runs it automatically) — until then this takes
                    // the 1...max fallback path.
                    let codes = model.colorPresetCodes(for: display)
                    HStack(spacing: 8) {
                        if model.ddcCapabilities[display.recordID] == nil {
                            Button(detectingModes ? "Detecting…" : "Detect…") { detectModes() }
                                .buttonStyle(.link).controlSize(.small)
                                .disabled(detectingModes)
                                .help("Ask the monitor which colour presets it supports")
                        }
                        if codes.isEmpty {
                            Text(model.colorPreset[display.recordID].map { model.presetName($0) } ?? "—")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Menu(model.colorPreset[display.recordID].map { model.presetName($0) } ?? "—") {
                                ForEach(codes, id: \.self) { code in
                                    Button(model.presetName(code)) { model.setColorPreset(code, for: display) }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
                if model.ddcWriteWasIgnored(0x14, for: display), let current = model.colorPreset[display.recordID] {
                    secondaryNote(String(localized: "The monitor stayed on \(model.presetName(current))."))
                }
                if detectFoundNothing {
                    secondaryNote(String(localized: "No capabilities reported"))
                } else if model.ddcCapabilities[display.recordID] == nil {
                    secondaryNote(String(localized: "Detecting asks the monitor which presets it supports. A few monitors stop answering DDC afterwards until power-cycled."))
                }
            }
            #endif
            ODDivider()
            ODRow(String(localized: "Colour profile")) {
                if model.colorProfileControllable[display.recordID] == true {
                    let profiles = model.availableColorProfilesCache
                    // Same-named files are different profiles: their file name tells them apart.
                    let sharedNames = Set(Dictionary(grouping: profiles, by: \.name).filter { $0.value.count > 1 }.keys)
                    let assigned = model.colorProfileAssignment[display.recordID]?.customURL
                    Menu(model.colorProfileName[display.recordID] ?? "—") {
                        Button("Factory Default") { Task { await model.resetColorProfile(for: display) } }
                        Divider()
                        ForEach(profiles) { profile in
                            let title = sharedNames.contains(profile.name)
                                ? "\(profile.name) — \(profile.url.lastPathComponent)" : profile.name
                            Button { Task { await model.setColorProfile(profile, for: display) } } label: {
                                if profile.isFile(assigned) { Label(title, systemImage: "checkmark") } else { Text(title) }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                } else {
                    Text("Unavailable").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if let error = model.colorProfileError[display.recordID] { secondaryNote(error) }
            if let issue = model.gammaIssueText(for: display), model.colorTemperature[display.recordID] != nil {
                secondaryNote(issue)  // the temperature above is set but isn't on screen
            }
        }
        if let reason = model.rotationUnavailableReason {
            // The backend reports an English sentence; look it up rather than compare against it.
            Text(reason.appLocalized)
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
    }

    private func secondaryNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Explicit, user-initiated capabilities read (the 0xF3 read is never run automatically — see
    /// `AppModel.refreshCapabilities`). Re-reads the preset afterwards so the menu, now narrowed to
    /// the advertised codes, shows the panel's real current mode.
    private func detectModes() {
        detectingModes = true
        detectFoundNothing = false
        Task {
            await model.refreshCapabilities(for: display)
            await model.refreshColorPreset(for: display)
            detectingModes = false
            guard model.ddcCapabilities[display.recordID] == nil else { return }
            detectFoundNothing = true
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            detectFoundNothing = false
        }
    }
}

// MARK: - Hardware controls (DDC, external only)

struct ControlsCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var confirmingReset = false
    @State private var resetting = false
    @State private var resetResult: DDCCommandOutcome?
    @State private var pendingPower: DDCPowerMode?
    @State private var sendingPower = false
    @State private var powerResult: (mode: DDCPowerMode, outcome: DDCCommandOutcome)?

    /// Sends a power command (already confirmed when it needs to be) and keeps what the transport
    /// reported for the caption under the row.
    private func sendPower(_ mode: DDCPowerMode) {
        pendingPower = nil
        powerResult = nil
        sendingPower = true
        Task {
            let outcome = await model.setPowerMode(mode, for: display)
            powerResult = (mode, outcome)
            sendingPower = false
        }
    }

    /// Shown under a slider whose last write the panel answered with a different value.
    private static let ignoredNote = String(localized: "The monitor ignored this change. Its picture mode may lock this setting.")

    var body: some View {
        ODCard(title: String(localized: "Controls"),
               footnote: String(localized: "Hardware controls sent over DDC/CI. Availability depends on the monitor.")) {
            // Brightness first, and always: it has a software fallback, so it's usable even on a
            // panel that reports none of the DDC extras below. Same model funnel as the popover.
            ODRow(String(localized: "Brightness"), secondary: model.brightnessCaption(for: display)) {
                sliderWithReadout(level: model.brightness[display.recordID] ?? 1) { value in
                    model.setBrightness(value, for: display)
                }
            }
            Toggle("Use software brightness for this monitor", isOn: Binding(
                get: { model.settings.softwareBrightnessDisplayIDs.contains(display.recordID.rawValue) },
                set: { enabled in Task { await model.setSoftwareBrightness(enabled, for: display) } }))
                .font(.caption)
            Text("Turn this on if DDC values change but the picture doesn’t. Software brightness uses the dimming method selected below.")
                .font(.caption).foregroundStyle(.secondary)
            if model.ddcWriteWasIgnored(0x10, for: display) { ignoredCaption(Self.ignoredNote) }
            ODDivider()
            let controls = HardwareControl.allCases.filter { model.ddcControl($0, for: display) != nil }
            #if !PUBLIC_API_ONLY
            if model.isAppleDisplay(display) {
                // FB-08: DDC is withheld from Apple displays; this is the explicit, per-display way in.
                Toggle("Allow DDC on this Apple display", isOn: Binding(
                    get: { model.appleDisplayDDCOverride(for: display) },
                    set: { allowed in Task { await model.setAppleDisplayDDCOverride(allowed, for: display) } }))
                    .font(.caption)
                Text("For experts. Some older Apple displays can end up with a screen that stays black after receiving DDC commands, and the fault may persist. Turn this on only if you know this model handles DDC.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
            let refusal = model.ddcBindingRefusal[display.recordID]
            if let refusal, refusal != .appleDisplay {
                // TR-06: refused on purpose — not a stuck channel the user should power-cycle.
                ODRow(String(localized: "No hardware control")) {}
                Text(DDCStatusText.refusal(refusal))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controls.isEmpty, refusal == nil {
                #if PUBLIC_API_ONLY
                ODRow(String(localized: "No hardware control")) {}
                Text("This build uses only public macOS interfaces, and monitor control over DDC needs private ones. Brightness uses software dimming.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                ODRow(String(localized: "No other adjustable hardware controls reported")) {}
                // A panel that answers nothing usually isn't DDC-less — its scaler's DDC channel is
                // often just stuck (a state that survives display sleep; only its own power button
                // clears it). Say so, or "unsupported" reads as a dead feature the user can't act on.
                Text("If this monitor supported hardware control before, its DDC channel may be stuck — try turning the monitor off and on with its own power button, then reopen this pane.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            } else {
                ForEach(Array(controls.enumerated()), id: \.element) { index, control in
                    if index > 0 { ODDivider() }
                    ODRow(control.label) {
                        sliderWithReadout(level: model.ddcControl(control, for: display) ?? 0.5) { value in
                            model.setHardwareControl(control, value, for: display)
                        }
                    }
                    if model.ddcWriteWasIgnored(control.vcp, for: display) {
                        ignoredCaption(Self.ignoredNote)
                    } else if model.ddcWriteDidFail(control.vcp, for: display) {
                        ignoredCaption(DDCStatusText.writeFailed)
                    }
                }
            }
            if let caption = model.groupSyncCaption(for: display) {
                ODDivider()
                Text(caption)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            #if !PUBLIC_API_ONLY
            if let status = model.adaptiveStatusLine(for: display) {
                ODDivider()
                Text(status)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            #endif
            // Input, power and reset are DDC writes whose bodies don't exist in the public-API-only
            // build (SD-03): that build explains their absence instead of offering no-op menus.
            #if !PUBLIC_API_ONLY
            ODDivider()
            ODRow(String(localized: "Input source")) {
                // Title = the input the monitor reported (AM-05); a request shows only in the caption.
                Menu(model.inputSource[display.recordID].map { model.inputName($0) } ?? "—") {
                    ForEach(AppModel.standardInputs, id: \.code) { input in
                        Button(input.name) { model.setInputSource(input.code, for: display) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let request = model.inputSwitch[display.recordID] {
                ignoredCaption(DDCStatusText.inputSwitch(request, inputName: model.inputName(request.requested)))
            }
            ODDivider()
            ODRow(String(localized: "Power"), secondary: String(localized: "Some displays can’t wake over DDC once off")) {
                Menu(sendingPower ? String(localized: "Sending…") : String(localized: "Set…")) {
                    ForEach(DDCPowerMode.allCases, id: \.self) { mode in
                        // The label comes from AutomationSchema (shared with the CLI), so it is
                        // looked up in the catalog here rather than extracted.
                        Button(mode.needsConfirmation ? mode.label.appLocalized + "…" : mode.label.appLocalized) {
                            if mode.needsConfirmation { pendingPower = mode } else { sendPower(mode) }
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(sendingPower)
                // AM-04: Standby/Off are confirmed with what they do and how to recover; the warning
                // is stronger when this display hosts the menu bar or is the last screen with a picture.
                .confirmationDialog(
                    pendingPower.map { DDCStatusText.powerConfirmTitle($0, displayName: model.displayName(for: display)) } ?? "",
                    isPresented: Binding(get: { pendingPower != nil }, set: { if !$0 { pendingPower = nil } }),
                    titleVisibility: .visible, presenting: pendingPower
                ) { mode in
                    Button(DDCStatusText.powerConfirmButton(mode), role: .destructive) { sendPower(mode) }
                    Button("Cancel", role: .cancel) {}
                } message: { mode in
                    Text(DDCStatusText.powerWarning(mode, risk: model.ddcPowerRisk(for: display)))
                }
            }
            if let powerResult {
                ignoredCaption(DDCStatusText.powerOutcome(powerResult.outcome, mode: powerResult.mode))
            }
            ODDivider()
            ODRow(String(localized: "Reset to defaults"), secondary: String(localized: "Restores the monitor’s factory settings")) {
                Button(resetting ? "Resetting…" : "Reset to defaults…") { confirmingReset = true }
                    .controlSize(.small)
                    .disabled(resetting)
            }
            if let resetResult {
                ignoredCaption(DDCStatusText.resetOutcome(resetResult))
                // AM-06: the app's own layers are a separate choice, offered only after a reset that
                // went through and only while there is something of OpenDisplay's to undo.
                if resetResult == .sent, model.hasSoftwareAdjustments(display) {
                    Button("Also Reset OpenDisplay’s Dimming and Colour Temperature") {
                        Task { await model.resetSoftwareAdjustments(for: display) }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                }
            }
            #else
            ODDivider()
            ignoredCaption(String(localized: "Input switching, monitor colour presets, monitor power and factory reset aren’t available in this build: they work over DDC, which needs private macOS interfaces."))
            #endif
        }
        .confirmationDialog("Reset “\(model.displayName(for: display))” to defaults?",
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset to Defaults", role: .destructive) {
                resetting = true
                resetResult = nil
                Task {
                    resetResult = await model.resetToDefaults(for: display)
                    resetting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The monitor is asked to restore its factory settings — brightness, contrast, colour preset and anything else it resets. OpenDisplay’s own software dimming and colour temperature stay as they are; you can reset them separately afterwards.")
        }
    }

    private func ignoredCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sliderWithReadout(level: Float, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { Double(level) }, set: { set(Float($0)) }), in: 0...1)
                .frame(width: 160)
            Text("\(Int((level * 100).rounded()))%")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

// MARK: - Software dimming (any display)

struct DimmingCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    /// Gamma alone bottoms out at its floor; the overlay methods can keep going (still capped short
    /// of full black by the composer). The method in force decides — the overlay while the
    /// custom-profile safeguard pauses gamma.
    private var range: ClosedRange<Double> {
        model.effectiveDimmingMethod == .gamma ? Double(DimmingComposer.gammaFloor)...1 : 0...1
    }

    private var footnote: String {
        switch model.settings.dimmingMethod {
        case .gamma:
            return String(localized: "Software gamma dimming, applied on top of hardware brightness. Works below the hardware minimum.")
        case .overlay:
            return String(localized: "A black overlay at adjustable opacity, applied on top of the picture. The menu bar stays available so you can always find your way back.")
        case .combined:
            return String(localized: "Gamma dimming plus a black overlay on top — darker than either method alone, and still never fully black.")
        }
    }

    var body: some View {
        ODCard(title: String(localized: "Dimming"), footnote: footnote) {
            ODRow(String(localized: "Software dimming")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(model.softwareDim[display.recordID] ?? 1) },
                                          set: { model.setSoftwareDim(Float($0), for: display) }), in: range)
                        .frame(width: 160)
                    Text("\(Int(((model.softwareDim[display.recordID] ?? 1) * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            ODRow(String(localized: "Method")) {
                Picker("", selection: Binding(
                    get: { model.settings.dimmingMethod },
                    set: { model.setDimmingMethod($0) })) {
                    Text("Gamma").tag(DimmingMethod.gamma)
                    Text("Overlay").tag(DimmingMethod.overlay)
                    Text("Combined").tag(DimmingMethod.combined)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if let issue = model.gammaIssueText(for: display) {
                Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            // The safeguard's override, offered only where it matters: a custom profile is assigned
            // somewhere, or the override is already on and should stay visible to be undone.
            if !model.customProfileDisplays.isEmpty || model.settings.allowGammaWithCustomProfiles {
                Toggle(isOn: Binding(get: { model.settings.allowGammaWithCustomProfiles },
                                     set: { model.setAllowGammaWithCustomProfiles($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow gamma with custom colour profiles")
                        Text("Applies to all displays. Custom ICC profiles combined with gamma changes can leave a screen black or tinted; if that happens, turn this off or choose a factory profile.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Use as

struct UseAsCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        ODCard(title: String(localized: "Use as")) {
            ODRow(String(localized: "Use as main display"), secondary: String(localized: "Menu bar and Dock appear here")) {
                Toggle("", isOn: Binding(get: { display.isMain },
                                         set: { on in if on { Task { await model.setMain(for: display) } } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(display.isMain || model.busy)
            }
            if !display.isMain {
                ODDivider()
                ODRow(String(localized: "Mirror to main display")) {
                    Toggle("", isOn: Binding(get: { display.isMirrored },
                                             set: { on in Task { await model.setMirrored(on, for: display) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.busy)
                }
            }
            ODDivider()
            // Named after what the provider in use really does: neither path powers the monitor off,
            // and the public fallback only mirrors it.
            switch model.logicalOffMethod {
            case .disconnect:
                ODRow(String(localized: "Disconnect display"),
                      secondary: String(localized: "Leaves the desktop; the monitor may go to standby. Reconnect from the menu.")) {
                    Button(String(localized: "Disconnect"), role: .destructive) {
                        Task { await model.setDisplayActive(false, for: display) }
                    }
                    .controlSize(.small)
                    .disabled(model.busy || !model.canTurnOff(display))
                }
            case .mirror:
                ODRow(String(localized: "Remove from desktop (mirror)"),
                      secondary: String(localized: "Mirrors it onto the main display, so it stays on, and keeps it listed for recovery. Undo from the menu.")) {
                    Button(String(localized: "Mirror onto Main"), role: .destructive) {
                        Task { await model.setDisplayActive(false, for: display) }
                    }
                    .controlSize(.small)
                    .disabled(model.busy || !model.canTurnOff(display))
                }
            }
        }
    }
}

// MARK: - Identity (rename)

private struct IdentityCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var alias = ""

    var body: some View {
        ODCard(title: String(localized: "Name")) {
            ODRow(String(localized: "Display name")) {
                TextField(model.displayName(for: display), text: $alias)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { Task { await model.setAlias(alias, for: display) } }
            }
        }
        // Re-seed when the segmented picker switches displays: the view keeps its identity, so an
        // onAppear-only seed would let Enter rename the new display with the previous one's alias.
        .onChange(of: display.recordID, initial: true) { alias = model.records[display.recordID]?.alias ?? "" }
    }
}

// MARK: - Information (read-only)

struct InformationCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        ODCard(title: String(localized: "Information")) {
            let info = model.displayInfo(for: display)
            ForEach(Array(info.enumerated()), id: \.element.label) { index, item in
                if index > 0 { ODDivider() }
                ODRow(item.label) {
                    Text(item.value).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
#endif
