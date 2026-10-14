#if os(macOS)
import AppKit
import AutomationSchema
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// The tray (menu-bar panel), laid out like BetterDisplay's app menu:
///
/// - notices on top (keep/revert countdown, degraded providers, update);
/// - one section per display: a header (glyph · name · mode · on/off switch) that collapses the
///   section, the frequent sliders (brightness, resolution, volume), and a «More» chevron that reveals
///   the per-display features — each expands in place and hides its siblings while open;
/// - managed-offline displays with a switch to bring them back;
/// - the Tools section (behind «…») and the button row (status · tools · settings · quit).
///
/// The panel host (`TrayPanelController`) keeps the top edge fixed, so expanding anything only
/// lengthens the panel downward. Everything here calls existing `AppModel` operations; nothing is a
/// placeholder — features the core lacks are simply not offered.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let onHeightChange: @MainActor (CGFloat) -> Void

    var body: some View {
        // No SwiftUI ScrollView: the panel host scrolls this in an AppKit scroll view pinned to the
        // top. The content keeps its natural height and is top-aligned even if the host is briefly
        // taller or shorter than it during a resize, so nothing ever shifts vertically.
        VStack(alignment: .leading, spacing: 6) {
            TrayNotices()
            devices
            if ui.toolsOpen { TrayToolsSection().transition(.trayReveal) }
            TrayButtonRow()
        }
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            onHeightChange(height)
        }
        .frame(width: TrayPanelController.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.controlActiveState, .key)
    }

    @ViewBuilder private var devices: some View {
        if model.phase == .scanning && model.displays.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning displays…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(10)
        } else if model.displays.isEmpty && model.managedOffline.isEmpty {
            Label("No displays detected", systemImage: "display.trianglebadge.exclamationmark")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(10)
        } else {
            ForEach(model.displays, id: \.recordID) { display in
                TrayDeviceSection(display: display)
            }
            ForEach(model.managedOffline) { offline in
                TrayOfflineSection(offline: offline)
            }
        }
    }
}

// MARK: - Notices

/// Top-of-panel notices, one concern per row: the keep/revert countdown always wins.
private struct TrayNotices: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState

    var body: some View {
        if model.isDegraded {
            TrayRow(icon: "exclamationmark.triangle", iconTint: ODColor.caution,
                    title: String(localized: "Some features are unavailable"), detail: SettingsSection.health.title) {
                ui.openSettings(.health)
            }
        }
        let update = SoftwareUpdatePolicy.presentation(for: model.updatePhase)
        if let badge = update.badge {
            TrayRow(icon: update.systemImage, iconTint: ODColor.accent, title: update.title.appLocalized, detail: badge) {
                model.checkForUpdates()
            }
        }
    }
}

/// Keep/revert prompt for a pending mode change. The panel host floats it over the bottom of the
/// panel, outside the scrolled content: always visible (even in a long scrolled list), and it never
/// pushes anything. It names the display, so it can't be mistaken for another screen's change.
struct TrayConfirmBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let pending = model.pendingRevert {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ODColor.caution)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep the new mode?").font(.system(size: 12, weight: .semibold))
                    Text("\(pending.message) · reverting in \(pending.secondsRemaining)s")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                TrayPillButton(String(localized: "Revert")) { Task { await model.revertArrangementChange() } }
                TrayPillButton(String(localized: "Keep"), prominent: true) { model.confirmArrangementChange() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ODColor.caution.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .padding(8)
            .frame(width: TrayPanelController.width)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
// MARK: - Display section

private struct TrayDeviceSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation
    @State private var modes: [TrayModeOption] = []

    private var key: String { display.recordID.rawValue }
    private var expanded: Bool { !ui.collapsedDevices.contains(key) }
    private var isExternal: Bool { display.displayClass != .builtIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrayDeviceHeader(display: display, expanded: expanded) {
                withAnimation(TrayMotion.expand) {
                    if expanded { ui.collapsedDevices.insert(key) } else { ui.collapsedDevices.remove(key) }
                }
            }
            if expanded && display.isActive {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        TrayBrightnessControl(display: display)
                        TrayResolutionSlider(display: display, modes: modes)
                        if isExternal, model.ddcControl(.volume, for: display) != nil {
                            TrayVolumeControl(display: display)
                        }
                    }
                    .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 4)
                    moreToggle
                    if ui.moreOpen.contains(key) {
                        TrayFeatureList(display: display, modes: modes)
                            .padding(.bottom, 4)
                            .transition(.trayReveal)
                    }
                }
                .transition(.trayReveal)
            }
        }
        .background(ODColor.fillQuaternary, in: RoundedRectangle(cornerRadius: 11))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .task(id: display.cgDisplayID) {
            reloadModes()
            await model.refreshBrightness(for: display)
            if isExternal { await model.refreshHardwareControls(for: display) }
        }
        .onChange(of: display.mode) { _, _ in reloadModes() }
    }

    private func reloadModes() {
        modes = display.cgDisplayID.map { TrayModeCatalog.options(for: $0) } ?? []
    }

    private var moreToggle: some View {
        let open = ui.moreOpen.contains(key)
        return Button {
            ui.toggle(\.moreOpen, key)
        } label: {
            HStack(spacing: 4) {
                Text(open ? "Hide" : "More").font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide display settings" : "Mode, refresh rate, color, rotation, monitor controls…")
        .accessibilityLabel(open ? "Hide display settings" : "More display settings")
        .accessibilityIdentifier("tray.more")
    }
}

private struct TrayDeviceHeader: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if NSEvent.modifierFlags.contains(.option) { identify() } else { toggle() }
            } label: {
                HStack(spacing: 9) {
                    TrayGlyph(symbol: trayGlyph(display.displayClass), highlighted: display.isMain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayName(for: display))
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collapse or expand. ⌥-click to identify the display")
            .accessibilityLabel(model.displayName(for: display))
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .accessibilityIdentifier("tray.header")
            TraySwitch(isOn: display.isActive, enabled: canDisconnect) { on in
                if !on { Task { await model.setDisplayActive(false, for: display) } }
            }
            .help(switchHelp)
            .accessibilityLabel("Display on")
            .accessibilityIdentifier("tray.header.switch")
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hovering ? ODColor.rowHover : .clear, in: RoundedRectangle(cornerRadius: 11))
        .onHover { hovering = $0 }
    }

    /// Offered only when the coordinator would accept it: another physical screen stays on.
    private var canDisconnect: Bool { !model.busy && model.canTurnOff(display) }

    /// Names what the switch really does with the provider in use: neither path powers the monitor
    /// off, and the public fallback leaves it lit, mirroring the main display.
    private var switchHelp: String {
        guard display.isActive else {
            return String(localized: "It isn’t part of the desktop right now, so there is nothing to switch off")
        }
        guard model.canTurnOff(display) else {
            return String(localized: "Turning this off would leave no physical display on")
        }
        switch model.logicalOffMethod {
        case .disconnect:
            return String(localized: "Disconnect it from the desktop — the monitor may go to standby but isn’t powered off. Bring it back from its card in this menu.")
        case .mirror:
            return String(localized: "Mirror it onto the main display — it stays on, showing the main display’s picture. Undo it from its card in this menu.")
        }
    }

    private var subtitle: String {
        guard display.isActive else {
            return display.isMirrored ? String(localized: "Mirroring another display") : String(localized: "Inactive")
        }
        var parts: [String] = []
        if let mode = display.mode {
            parts.append(TrayModeCatalog.sizeText(mode))
            parts.append(TrayModeCatalog.refreshText(mode.refreshHz))
            if mode.isHiDPI { parts.append("HiDPI") }
        }
        if model.isBlackedOut(display) { parts.append(String(localized: "blacked out")) }
        if display.isMirrored { parts.append(String(localized: "mirrored")) }
        return parts.joined(separator: " · ")
    }

    private func identify() {
        guard let cgID = display.cgDisplayID else { return }
        ui.identify(cgID, model.displayName(for: display), subtitle)
    }
}

private struct TrayOfflineSection: View {
    @EnvironmentObject private var model: AppModel
    let offline: AppModel.OfflineDisplay

    /// What OpenDisplay did to it, in the provider's own terms — not "turned off": neither path
    /// powers the monitor down.
    private var offStatus: String {
        switch model.logicalOffMethod {
        case .disconnect: return String(localized: "Disconnected by OpenDisplay")
        case .mirror: return String(localized: "Mirrored onto the main display by OpenDisplay")
        }
    }

    private var failedStatus: String {
        switch model.logicalOffMethod {
        case .disconnect: return String(localized: "Didn’t reconnect")
        case .mirror: return String(localized: "Still mirrored")
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            TrayGlyph(symbol: trayGlyph(offline.displayClass), highlighted: false).opacity(0.55)
            VStack(alignment: .leading, spacing: 1) {
                Text(offline.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                if offline.reconnectFailedAt == nil {
                    Text(offStatus).font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    // macOS accepted the reconnect but no display appeared — keep the way out visible.
                    HStack(spacing: 4) {
                        Text(failedStatus).font(.system(size: 11)).foregroundStyle(ODColor.caution)
                        Button("Recovery steps…") { NSWorkspace.shared.open(ReconnectVerification.recoveryGuideURL) }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }
            Spacer(minLength: 4)
            TraySwitch(isOn: false, enabled: !model.busy) { on in
                if on { Task { await model.reconnectOffline(offline) } }
            }
            .help(model.logicalOffMethod == .mirror ? String(localized: "Stop mirroring the display")
                                                    : String(localized: "Reconnect the display"))
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(ODColor.fillQuaternary, in: RoundedRectangle(cornerRadius: 11))
    }
}

// MARK: - Main-level sliders

private struct TrayBrightnessControl: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    private var level: Double { Double(model.brightness[display.recordID] ?? 0.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TraySlider(value: level, icon: "sun.max.fill",
                           valueText: "\(Int((level * 100).rounded()))%",
                           accessibilityLabel: String(localized: "Brightness")) { model.setBrightness(Float($0), for: display) }
                if model.xdrCapable(display) { xdrButton }
            }
            let captions = [model.brightnessCaption(for: display), model.groupSyncCaption(for: display)].compactMap { $0 }
            if !captions.isEmpty || model.ddcWriteWasIgnored(0x10, for: display) {
                Text((captions + (model.ddcWriteWasIgnored(0x10, for: display) ? [String(localized: "the monitor ignored the value")] : []))
                        .joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 4)
            }
        }
    }

    /// XDR boost (Labs): brighter-than-SDR-max on the built-in XDR panel. Binary, like the old menu.
    private var xdrButton: some View {
        let on = (model.xdrBoostFraction[display.recordID] ?? 0) > 0
        return Button {
            model.setXDRBoost(on ? 0 : XDRBrightnessPolicy.defaultBoostFraction, for: display)
        } label: {
            Image(systemName: on ? "sun.max.circle.fill" : "sun.max.circle")
                .font(.system(size: 17)).foregroundStyle(on ? ODColor.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        // The boost is a gamma table, so the custom-profile safeguard pauses it too.
        .disabled(model.gammaBlockedByCustomProfile)
        .help(model.gammaBlockedByCustomProfile
              ? String(localized: "paused: custom colour profile")
              : String(localized: "XDR boost: SDR brightness above the normal maximum"))
    }
}

private struct TrayVolumeControl: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        let level = Double(model.ddcControl(.volume, for: display) ?? 0)
        let muted = model.ddcAudioMuted[display.recordID] == true || level <= 0
        // TB-03: the icon is a button only when a mute toggle has something truthful to do.
        let mute = model.muteAction(for: display)
        TraySlider(value: level, icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                   valueText: "\(Int((level * 100).rounded()))%", accessibilityLabel: String(localized: "Volume"),
                   leadingAction: mute == .unavailable ? nil : { model.toggleMute(for: display) }) {
            model.setHardwareControl(.volume, Float($0), for: display, showsOSD: false)
        }
        .help(DDCStatusText.volumeHelp(mute))
    }
}

/// BetterDisplay-style resolution slider: one stop per size in the panel's aspect ratio; dragging
/// previews the size, releasing applies it (with the usual keep/revert countdown). Each stop keeps
/// the current refresh rate, depth and density where the display offers them; a stop that can't
/// says what it changes in the caption while it is being dragged to.
private struct TrayResolutionSlider: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation
    let modes: [TrayModeOption]
    @State private var dragIndex: Int?
    /// Released position while macOS switches the mode — the knob stays there instead of snapping
    /// back to the old size and then jumping again.
    @State private var applyingIndex: Int?

    var body: some View {
        // Hidden for a mirror target — `mirrorSourceID` names that role directly, whereas "is main"
        // says nothing about it — and while the applied mode is unknown, because the knob could
        // only guess where it sits.
        if let mode = display.mode, display.mirrorSourceID == nil {
            let stops = TrayModeCatalog.sliderStops(modes, current: mode)
            if stops.count > 1, let current = DisplayModeCatalog.index(of: mode, in: stops) {
                let shown = dragIndex ?? applyingIndex ?? current
                let option = stops[min(shown, stops.count - 1)]
                VStack(alignment: .leading, spacing: 3) {
                    TrayStepSlider(count: stops.count, index: applyingIndex ?? current,
                                   markers: stops.indices.filter { stops[$0].isNative || stops[$0].isDefault },
                                   icon: "arrow.up.left.and.arrow.down.right",
                                   valueText: TrayModeCatalog.sizeText(option.mode),
                                   enabled: !ui.isModeLocked(model, for: display),
                                   onDrag: { dragIndex = $0 }) { index in
                        dragIndex = nil
                        guard index != current else { return }
                        applyingIndex = index
                        ui.applyMode(stops[index].mode, for: display, model: model) { applyingIndex = nil }
                    }
                    HStack(spacing: 6) {
                        if applyingIndex != nil {
                            ProgressView().controlSize(.mini)
                            Text("Applying mode…").font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            Text(caption(option, current: mode, dragging: dragIndex != nil && dragIndex != current))
                                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                    .frame(height: 14)
                    // Logical size, framebuffer, rate and density spelled out separately.
                    .help(AppModel.modeLabel(option.mode))
                }
            }
        }
    }

    private func caption(_ option: TrayModeOption, current: DisplayMode, dragging: Bool) -> String {
        if model.pendingRevert != nil {
            return ui.isModeLocked(model, for: display)
                ? String(localized: "Confirm the other display's change at the bottom of the panel first")
                : (dragging ? String(localized: "release — the previous step will be kept")
                            : String(localized: "You can keep adjusting · confirm at the bottom"))
        }
        if let error = model.modeChangeError, !dragging { return error }
        // While dragging, the word "Resolution" makes room for what the stop would change.
        var parts = dragging ? [] : [String(localized: "Resolution")]
        // The native flag is what the display reports — not proof of unscaled output.
        if option.isNative {
            parts.append(String(localized: "native"))
        } else if option.isDefault {
            parts.append(String(localized: "recommended by macOS"))
        }
        if option.mode.isHiDPI { parts.append("HiDPI") }
        if dragging {
            let change = DisplayModeCatalog.change(from: current, to: option.mode)
            if change.density, !option.mode.isHiDPI { parts.append(String(localized: "no HiDPI")) }
            if change.refreshRate {
                let rate = TrayModeCatalog.refreshText(option.mode.refreshHz)
                let now = TrayModeCatalog.refreshText(current.refreshHz)
                parts.append(String(localized: "\(rate) instead of \(now)"))
            }
            if change.bitDepth, let bits = option.mode.bitDepth { parts.append(String(localized: "\(bits)-bit")) }
            parts.append(String(localized: "release to apply"))
        }
        return parts.joined(separator: " · ")
    }
}
// MARK: - «More»: per-display features

private struct TrayFeatureList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation
    let modes: [TrayModeOption]

    private var key: String { display.recordID.rawValue }
    private var isExternal: Bool { display.displayClass != .builtIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            TrayDivider()
            feature("mode", "rectangle.on.rectangle", String(localized: "Display mode"), modeSummary) {
                TrayModeList(display: display, modes: modes)
            }
            if TrayModeCatalog.refreshRates(modes, current: display.mode).count > 1 {
                feature("refresh", "arrow.triangle.2.circlepath", String(localized: "Refresh rate"),
                        display.mode.map { TrayModeCatalog.refreshText($0.refreshHz) }) {
                    TrayRefreshList(display: display, modes: modes)
                }
            }
            feature("toggles", "switch.2", String(localized: "Toggles"), nil) {
                TrayToggles(display: display, modes: modes)
            }
            feature("image", "camera.filters", String(localized: "Picture"), imageSummary) {
                TrayImageAdjustments(display: display)
            }
            #if !PUBLIC_API_ONLY
            if isExternal {
                feature("device", "slider.horizontal.3", String(localized: "Monitor controls"), "DDC") {
                    TrayDeviceControl(display: display)
                }
                feature("input", "cable.connector.horizontal", String(localized: "Input source"),
                        model.inputSource[display.recordID].map { model.inputName($0) }) {
                    TrayInputList(display: display)
                }
                // TR-07: the monitor's own picture preset (VCP 0x14), not a connection colour format.
                feature("colorMode", "paintpalette", String(localized: "Monitor color preset"),
                        model.colorPreset[display.recordID].map { model.presetName($0) }) {
                    TrayColorPresetList(display: display)
                }
            }
            #endif
            feature("profile", "swatchpalette", String(localized: "Color profile"), model.colorProfileName[display.recordID]) {
                TrayColorProfileList(display: display)
            }
            feature("rotation", "rotate.right", String(localized: "Display rotation"), "\(model.currentRotation(for: display))°") {
                TrayRotation(display: display)
            }
            if model.displays.count > 1 {
                feature("mirror", "rectangle.on.rectangle.angled", String(localized: "Mirroring"),
                        display.isMirrored ? String(localized: "On") : nil) {
                    TrayMirroring(display: display)
                }
            }
            feature("pip", "pip", String(localized: "Picture in Picture and streaming"), nil) {
                TrayPictureInPicture(display: display)
            }
            feature("manage", "info.circle", String(localized: "Manage display"), nil) {
                TrayManageDisplay(display: display)
            }
        }
        .padding(.horizontal, 4)
    }

    private var modeSummary: String? {
        guard let mode = display.mode else { return nil }
        return TrayModeCatalog.sizeText(mode) + (mode.isHiDPI ? " HiDPI" : "")
    }

    private var imageSummary: String? {
        model.colorTemperature[display.recordID].map { "\(Int($0)) K" }
    }

    /// A feature row that unfolds in place under itself. Unlike BetterDisplay it neither hides its
    /// siblings nor closes the other open features: the row that was clicked never moves, only what
    /// is below it slides down.
    @ViewBuilder
    private func feature<Content: View>(_ id: String, _ icon: String, _ title: String, _ summary: String?,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        let fullID = "\(key)|\(id)"
        let isOpen = ui.openFeatures.contains(fullID)
        VStack(alignment: .leading, spacing: 0) {
            TrayRow(icon: icon, title: title, detail: summary, disclosure: isOpen ? .open : .closed,
                    identifier: "tray.feature.\(id)") {
                ui.resetConfirm = nil
                ui.powerConfirm = nil
                ui.toggle(\.openFeatures, fullID)
            }
            if isOpen {
                content()
                    .padding(.leading, 8).padding(.trailing, 6).padding(.top, 2).padding(.bottom, 8)
                    .transition(.trayReveal)
            }
        }
        .clipped()
    }
}

private struct TrayModeList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation
    let modes: [TrayModeOption]

    private var key: String { display.recordID.rawValue }

    var body: some View {
        let current = display.mode
        let showAll = ui.showAllModes.contains(key)
        let recommended = modes.filter { $0.isNative || $0.isDefault }
        let favoriteModes = model.favoriteResolutions(among: modes.map(\.mode), for: display)
        let favorites = favoriteModes.compactMap { mode in modes.first { $0.mode == mode } }
            .filter { option in !recommended.contains(option) }
        let pinned = Set(recommended + favorites)
        let rest = (showAll ? modes : TrayModeCatalog.compact(modes, current: current)).filter { !pinned.contains($0) }

        VStack(alignment: .leading, spacing: 1) {
            if !recommended.isEmpty {
                TraySubheader(String(localized: "Native and recommended"))
                ForEach(recommended) { row($0, current: current) }
            }
            if !favorites.isEmpty {
                TraySubheader(String(localized: "Favorites"))
                ForEach(favorites) { row($0, current: current) }
            }
            let unavailable = model.unavailableFavoriteKeys(among: modes.map(\.mode), for: display)
            if !unavailable.isEmpty {
                TraySubheader(String(localized: "Favorites not offered now"))
                ForEach(unavailable, id: \.self) { unavailableRow($0) }
            }
            TraySubheader(showAll ? String(localized: "All modes") : String(localized: "Other sizes"))
            ForEach(rest) { row($0, current: current) }
            // Below the rows on purpose: a message appearing here never pushes the row that was clicked.
            if let error = model.modeChangeError { TrayNote(error, tint: ODColor.caution) }
            TrayCheckRow(title: String(localized: "Show all variants (non-HiDPI, all refresh rates)"), isOn: showAll) {
                if showAll { ui.showAllModes.remove(key) } else { ui.showAllModes.insert(key) }
            }
            .padding(.top, 4)
            // The native flag is reported metadata; whether the panel shows the framebuffer 1:1
            // isn't observable here, so the note must not promise "sharpest" or "no scaling".
            TrayNote(String(localized: "“Native” is the mode the display reports as native; it doesn’t guarantee unscaled output. Sizes are in points — a HiDPI framebuffer is larger. A new mode has to be confirmed, or it reverts on its own."))
        }
    }

    private func row(_ option: TrayModeOption, current: DisplayMode?) -> some View {
        let isCurrent = option.mode == current
        let favorite = model.isFavoriteResolution(option.mode, for: display)
        return TrayChoiceRow(selected: isCurrent, enabled: !ui.isModeLocked(model, for: display) || isCurrent, action: {
            guard !isCurrent else { return }
            ui.applyMode(option.mode, for: display, model: model)
        }) {
            HStack(spacing: 5) {
                Text(TrayModeCatalog.sizeText(option.mode)).font(.system(size: 12).monospacedDigit())
                    .help(AppModel.modeLabel(option.mode))  // logical vs framebuffer size, exact rate
                if option.mode.isHiDPI { TrayTag("HiDPI", tint: ODColor.accent) }
                Text(TrayModeCatalog.refreshText(option.mode.refreshHz))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if option.isNative { TrayTag(String(localized: "native"), tint: ODColor.connected) }
                if option.isDefault { TrayTag(String(localized: "default"), tint: .secondary) }
                Spacer(minLength: 2)
                Button { model.toggleFavoriteResolution(option.mode, for: display) } label: {
                    Image(systemName: favorite ? "star.fill" : "star").font(.system(size: 10))
                        .foregroundStyle(favorite ? Color.yellow : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(favorite ? "Remove from favorites" : "Add to favorites")
            }
        }
    }

    /// A favourite the display doesn't offer right now: shown as it was stored — never matched to a
    /// near mode — not selectable, and removable.
    private func unavailableRow(_ favoriteKey: String) -> some View {
        let stored = FavoriteResolutions.storedMode(forKey: favoriteKey)
        return HStack(spacing: 5) {
            if let stored {
                Text(TrayModeCatalog.sizeText(stored)).font(.system(size: 12).monospacedDigit())
                if stored.isHiDPI { TrayTag("HiDPI", tint: .secondary) }
                Text(TrayModeCatalog.refreshText(stored.refreshHz)).font(.system(size: 10.5))
            } else {
                Text(verbatim: favoriteKey).font(.system(size: 12).monospacedDigit())  // older rounded key
            }
            Spacer(minLength: 2)
            Button { model.removeFavoriteKey(favoriteKey, for: display) } label: {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color.yellow)
            }
            .buttonStyle(.plain)
            .help("Remove from favorites")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 24).padding(.trailing, 6).padding(.vertical, 4)  // aligned with the choice rows' text
        .help(stored.map(AppModel.modeLabel) ?? favoriteKey)
    }
}

private struct TrayRefreshList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation
    let modes: [TrayModeOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(TrayModeCatalog.refreshRates(modes, current: display.mode)) { option in
                let isCurrent = option.mode == display.mode
                TrayChoiceRow(selected: isCurrent, enabled: !ui.isModeLocked(model, for: display) || isCurrent, action: {
                    guard !isCurrent else { return }
                    ui.applyMode(option.mode, for: display, model: model)
                }) {
                    Text(TrayModeCatalog.refreshText(option.mode.refreshHz)).font(.system(size: 12).monospacedDigit())
                }
            }
            if let error = model.modeChangeError { TrayNote(error, tint: ODColor.caution) }
        }
    }
}

private struct TrayToggles: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation
    let modes: [TrayModeOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let counterpart = TrayModeCatalog.densityCounterpart(modes, current: display.mode) {
                TraySwitchRow(title: "HiDPI (Retina)", isOn: display.mode?.isHiDPI ?? false,
                              enabled: !ui.isModeLocked(model, for: display)) { _ in
                    ui.applyMode(counterpart.mode, for: display, model: model)
                }
            }
            TraySwitchRow(title: String(localized: "Main display"), detail: String(localized: "menu bar and Dock"),
                          isOn: display.isMain, enabled: !display.isMain && !model.busy) { on in
                if on { Task { await model.setMain(for: display) } }
            }
            // Black Out on the last lit screen would leave nothing to click — offer it only while
            // another active screen stays visible.
            let otherLit = model.displays.contains {
                $0.recordID != display.recordID && $0.isActive && !model.isBlackedOut($0)
            }
            // Without gamma (overlay-only dimming, or the custom-profile safeguard) Black Out is the
            // overlay alone, which sits under the menu bar — so the menu bar stays lit.
            TraySwitchRow(title: String(localized: "Black Out"),
                          detail: model.effectiveDimmingMethod == .overlay
                              ? String(localized: "black except the menu bar") : String(localized: "fully black screen"),
                          isOn: model.isBlackedOut(display),
                          enabled: model.isBlackedOut(display) || otherLit) { _ in
                model.toggleBlackOut(for: display)
            }
            TraySwitchRow(title: String(localized: "FaceLight"), detail: String(localized: "white screen light"),
                          isOn: model.isFaceLightActive(display)) { _ in
                model.toggleFaceLight(for: display)
            }
            if model.xdrCapable(display) {
                // The boost is a gamma table: unavailable while the custom-profile safeguard pauses gamma.
                TraySwitchRow(title: String(localized: "XDR boost"),
                              detail: model.gammaBlockedByCustomProfile ? String(localized: "paused: custom colour profile") : nil,
                              isOn: (model.xdrBoostFraction[display.recordID] ?? 0) > 0,
                              enabled: !model.gammaBlockedByCustomProfile) { on in
                    model.setXDRBoost(on ? XDRBrightnessPolicy.defaultBoostFraction : 0, for: display)
                }
            }
            if display.displayClass != .builtIn {
                TraySwitchRow(title: String(localized: "Software brightness"), detail: String(localized: "if the monitor ignores DDC"),
                              isOn: model.settings.softwareBrightnessDisplayIDs.contains(display.recordID.rawValue)) { on in
                    Task { await model.setSoftwareBrightness(on, for: display) }
                }
            }
        }
    }
}

private struct TrayImageAdjustments: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        let id = display.recordID
        let minK = Double(ColorTemperatureCurve.minKelvin), maxK = Double(ColorTemperatureCurve.maxKelvin)
        let kelvin = Double(model.colorTemperature[id] ?? ColorTemperatureCurve.neutralKelvin)
        // The method in force: overlay while the custom-profile safeguard pauses gamma.
        let dimFloor = model.effectiveDimmingMethod == .gamma ? Double(DimmingComposer.gammaFloor) : 0
        let dim = Double(model.softwareDim[id] ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            TrayLabeled(String(localized: "Color temperature"),
                        value: model.colorTemperature[id] == nil ? String(localized: "neutral") : "\(Int(kelvin)) K") {
                TraySlider(value: (kelvin - minK) / (maxK - minK), icon: "thermometer.medium",
                           valueText: "", accessibilityLabel: String(localized: "Color temperature"), showsValue: false) {
                    model.setColorTemperature(Float(minK + $0 * (maxK - minK)), for: display)
                }
            }
            if model.colorTemperature[id] != nil {
                TrayPillButton(String(localized: "Reset temperature")) {
                    model.setColorTemperature(ColorTemperatureCurve.neutralKelvin, for: display)
                }
            }
            TrayLabeled(String(localized: "Software dimming"), value: "\(Int((dim * 100).rounded()))%") {
                TraySlider(value: dim, icon: "moon.fill", valueText: "", accessibilityLabel: String(localized: "Software dimming"),
                           showsValue: false) { model.setSoftwareDim(Float(max(dimFloor, $0)), for: display) }
            }
            TraySegmented(options: [(String(localized: "Gamma"), DimmingMethod.gamma),
                                    (String(localized: "Overlay"), DimmingMethod.overlay),
                                    (String(localized: "Both"), DimmingMethod.combined)],
                          selection: model.settings.dimmingMethod) { model.setDimmingMethod($0) }
            if let issue = model.gammaIssueText(for: display) { TrayNote(issue, tint: ODColor.caution) }
            TrayNote(String(localized: "The dimming method is shared by all displays. Temperature and dimming stay until you quit OpenDisplay."))
        }
    }
}

#if !PUBLIC_API_ONLY
private struct TrayDeviceControl: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation
    @State private var resetting = false
    @State private var sendingPower = false
    @State private var powerResult: PowerResult?
    @State private var resetResult: DDCCommandOutcome?

    /// What the last power command from this card reported (never a confirmed effect).
    private struct PowerResult { let mode: DDCPowerMode; let outcome: DDCCommandOutcome }

    /// The power command awaiting its second click on this display, if any.
    private var pendingPower: DDCPowerMode? {
        guard let pending = ui.powerConfirm else { return nil }
        let parts = pending.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == display.recordID.rawValue else { return nil }
        return DDCPowerMode(rawValue: parts[1])
    }

    private func askPower(_ mode: DDCPowerMode) {
        powerResult = nil
        ui.powerConfirm = "\(display.recordID.rawValue)|\(mode.rawValue)"
    }

    var body: some View {
        let controls = HardwareControl.allCases.filter { model.ddcControl($0, for: display) != nil }
        VStack(alignment: .leading, spacing: 8) {
            if let refusal = model.ddcBindingRefusal[display.recordID] {
                // Deliberately not talking DDC (TR-06/FB-08) — "didn't respond" would send the user
                // power-cycling a monitor that was never asked anything.
                TrayNote(DDCStatusText.refusal(refusal), tint: ODColor.caution)
            } else if controls.isEmpty {
                TrayNote(String(localized: "The monitor didn't respond over DDC. If control worked before, turn the monitor off and on with its power button and retry."))
                TrayPillButton(String(localized: "Retry DDC probe")) {
                    model.retryDDCDiscoveryIfDead(for: display)
                    Task { await model.refreshHardwareControls(for: display) }
                }
            }
            ForEach(controls, id: \.self) { control in
                let value = Double(model.ddcControl(control, for: display) ?? 0)
                TrayLabeled(control.label, value: "\(Int((value * 100).rounded()))%") {
                    TraySlider(value: value, icon: control.icon, valueText: "", accessibilityLabel: control.label,
                               showsValue: false,
                               leadingAction: control == .volume && model.muteAction(for: display) != .unavailable
                                   ? { model.toggleMute(for: display) } : nil) {
                        model.setHardwareControl(control, Float($0), for: display, showsOSD: false)
                    }
                }
                if model.ddcWriteWasIgnored(control.vcp, for: display) {
                    TrayNote(String(localized: "The monitor didn't apply the change — its current picture mode may be blocking it."))
                } else if model.ddcWriteDidFail(control.vcp, for: display) {
                    TrayNote(DDCStatusText.writeFailed, tint: ODColor.caution)
                }
            }
            TraySubheader(String(localized: "Power"))
            // Two-step like factory reset (AM-04): the first click only explains what a DDC power
            // command does here and how to recover; nothing is sent until the second click.
            if let mode = pendingPower {
                let risk = model.ddcPowerRisk(for: display)
                TrayNote(DDCStatusText.powerWarning(mode, risk: risk),
                         tint: risk == .otherScreensRemain ? .secondary : ODColor.caution)
                HStack(spacing: 6) {
                    TrayPillButton(sendingPower ? String(localized: "Sending…") : DDCStatusText.powerConfirmButton(mode),
                                   destructive: true) {
                        guard !sendingPower else { return }
                        sendingPower = true
                        Task {
                            let outcome = await model.setPowerMode(mode, for: display)
                            powerResult = PowerResult(mode: mode, outcome: outcome)
                            sendingPower = false
                            ui.powerConfirm = nil
                        }
                    }
                    TrayPillButton(String(localized: "Cancel")) { ui.powerConfirm = nil }
                }
            } else {
                HStack(spacing: 6) {
                    TrayPillButton(String(localized: "Standby…")) { askPower(.standby) }
                    TrayPillButton(String(localized: "Turn off…")) { askPower(.off) }
                }
                TrayNote(String(localized: "Some monitors can't be woken over DDC — turn them on with the power button."))
            }
            if let powerResult {
                TrayNote(DDCStatusText.powerOutcome(powerResult.outcome, mode: powerResult.mode),
                         tint: powerResult.outcome == .sent ? .secondary : ODColor.caution)
            }
            TraySubheader(String(localized: "Reset"))
            if ui.resetConfirm == display.recordID.rawValue {
                HStack(spacing: 6) {
                    TrayPillButton(resetting ? String(localized: "Resetting…") : String(localized: "Reset monitor"), destructive: true) {
                        guard !resetting else { return }
                        resetting = true
                        resetResult = nil
                        Task {
                            resetResult = await model.resetToDefaults(for: display)
                            resetting = false
                            ui.resetConfirm = nil
                        }
                    }
                    TrayPillButton(String(localized: "Cancel")) { ui.resetConfirm = nil }
                }
                TrayNote(String(localized: "The monitor is asked to restore its factory settings — brightness, contrast, color preset and whatever else it resets. OpenDisplay's own dimming and color temperature stay as they are."))
            } else {
                TrayPillButton(String(localized: "Factory reset…")) { ui.resetConfirm = display.recordID.rawValue }
            }
            if let resetResult {
                TrayNote(DDCStatusText.resetOutcome(resetResult),
                         tint: resetResult == .sent ? .secondary : ODColor.caution)
                // AM-06: the app's own layers are a separate, explicit choice — offered only once the
                // monitor reset actually went through, and only if there is something to undo.
                if resetResult == .sent, model.hasSoftwareAdjustments(display) {
                    TrayPillButton(String(localized: "Also reset OpenDisplay's dimming and temperature")) {
                        Task { await model.resetSoftwareAdjustments(for: display) }
                    }
                }
            }
        }
        .task(id: display.recordID) { await model.refreshHardwareControls(for: display) }
    }
}

private struct TrayInputList: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // The checkmark is the input the MONITOR reported (AM-05); a request is only a note below.
            ForEach(AppModel.standardInputs, id: \.code) { input in
                TrayChoiceRow(selected: model.inputSource[display.recordID] == input.code,
                              action: { model.setInputSource(input.code, for: display) }) {
                    Text(input.name).font(.system(size: 12))
                }
            }
            if let request = model.inputSwitch[display.recordID] {
                TrayNote(DDCStatusText.inputSwitch(request, inputName: model.inputName(request.requested)),
                         tint: request.status == .failed || request.status == .notSent ? ODColor.caution : .secondary)
            }
            TrayNote(String(localized: "After switching, the monitor shows the other input — switch back with the monitor's buttons."))
        }
        .task(id: display.recordID) { await model.refreshInputSource(for: display) }
    }
}

private struct TrayColorPresetList: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var detecting = false

    var body: some View {
        let codes = model.colorPresetCodes(for: display)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(codes, id: \.self) { code in
                TrayChoiceRow(selected: model.colorPreset[display.recordID] == code,
                              action: { model.setColorPreset(code, for: display) }) {
                    Text(model.presetName(code)).font(.system(size: 12))
                }
            }
            if model.ddcWriteWasIgnored(0x14, for: display), let current = model.colorPreset[display.recordID] {
                TrayNote(String(localized: "The monitor kept the “\(model.presetName(current))” preset."), tint: ODColor.caution)
            }
            if model.ddcCapabilities[display.recordID] == nil {
                TrayPillButton(detecting ? String(localized: "Detecting…") : String(localized: "Detect supported presets")) {
                    detecting = true
                    Task {
                        await model.refreshCapabilities(for: display)
                        await model.refreshColorPreset(for: display)
                        detecting = false
                    }
                }
                .padding(.top, 4)
                TrayNote(String(localized: "On some monitors, a capabilities request hangs DDC until the power is cycled."))
            }
        }
        .task(id: display.recordID) { await model.refreshColorPreset(for: display) }
    }
}
#endif

private struct TrayColorProfileList: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if model.colorProfileControllable[display.recordID] == true {
                // Rows are marked by the assigned FILE: two installed profiles can share a name.
                // Unknown until the assignment has been read, so nothing is marked before that.
                let assignment = model.colorProfileAssignment[display.recordID]
                let profiles = model.availableColorProfilesCache
                let sharedNames = Set(Dictionary(grouping: profiles, by: \.name).filter { $0.value.count > 1 }.keys)
                TrayChoiceRow(selected: assignment?.isFactory == true,
                              action: { Task { await model.resetColorProfile(for: display) } }) {
                    Text("Factory default").font(.system(size: 12))
                }
                ForEach(profiles) { profile in
                    TrayChoiceRow(selected: profile.isFile(assignment?.customURL),
                                  action: { Task { await model.setColorProfile(profile, for: display) } }) {
                        HStack(spacing: 4) {
                            Text(profile.name).font(.system(size: 12)).lineLimit(1)
                            if sharedNames.contains(profile.name) {
                                // Same description, different file: the file name tells them apart.
                                Text(profile.url.lastPathComponent).font(.system(size: 10))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .help(profile.url.path)
                }
                if let error = model.colorProfileError[display.recordID] { TrayNote(error, tint: ODColor.caution) }
            } else {
                TrayNote(String(localized: "macOS doesn't allow changing this display's profile."))
            }
        }
        .task(id: display.recordID) { await model.refreshColorProfile(for: display) }
    }
}

private struct TrayRotation: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.rotationWritable {
                TraySegmented(options: [0, 90, 180, 270].map { ("\($0)°", $0) },
                              selection: model.currentRotation(for: display), enabled: !model.busy) { degrees in
                    Task { await model.setRotation(degrees, for: display) }
                }
                TrayNote(String(localized: "Experimental feature. If it fails, the displays reconnect automatically."))
            } else {
                // The read-only backend's reason is an English sentence meant for logs and the CLI;
                // the tray words it itself.
                TrayNote(model.rotationUnavailableReason == ReadOnlyRotationBackend.unavailableReason
                         ? String(localized: "Safe rotation isn't available on this version of macOS.")
                         : (model.rotationUnavailableReason
                            ?? String(localized: "Rotation is off. Turn it on in “\(SettingsSection.health.title) → Labs”.")))
                HStack(spacing: 6) {
                    TrayPillButton(String(localized: "Labs in Settings")) { ui.openSettings(.health) }
                    TrayPillButton(String(localized: "System Displays settings")) { ui.close(); model.openDisplaySettings() }
                }
            }
        }
    }
}

private struct TrayMirroring: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if display.isMain {
                TraySubheader(String(localized: "Show this display on:"))
                ForEach(model.displays.filter { !$0.isMain && $0.isActive }, id: \.recordID) { other in
                    TraySwitchRow(title: model.displayName(for: other), isOn: other.isMirrored, enabled: !model.busy) { on in
                        Task { await model.setMirrored(on, for: other) }
                    }
                }
            } else {
                TraySwitchRow(title: String(localized: "Mirror the main display"), isOn: display.isMirrored, enabled: !model.busy) { on in
                    Task { await model.setMirrored(on, for: display) }
                }
            }
            TrayNote(String(localized: "Mirroring works only with the main display."))
        }
    }
}

private struct TrayPictureInPicture: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    /// The display whose menu this sits in — the capture source it opens for (AM-08).
    let display: DisplayObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TrayNote(String(localized: "A picture-in-picture window of any display or window, rotation, flipping, and LUTs are set up in the capture window."))
            TrayPillButton(String(localized: "Open Screen Capture…")) {
                if let cgID = display.cgDisplayID {
                    CapturePresentation.shared.request(displayID: cgID, name: model.displayName(for: display))
                }
                ui.openSettings(.capture)
            }
        }
    }
}

private struct TrayManageDisplay: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState
    let display: DisplayObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.displayInfo(for: display).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.label).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(item.value).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 6) {
                TrayPillButton(String(localized: "Identify")) {
                    guard let cgID = display.cgDisplayID else { return }
                    ui.identify(cgID, model.displayName(for: display),
                                display.mode.map { TrayModeCatalog.sizeText($0) } ?? "")
                }
                TrayPillButton(String(localized: "All settings…")) {
                    model.selectedDisplayID = display.recordID
                    ui.openSettings(.displays)
                }
            }
        }
    }
}

// MARK: - Tools and button row

private struct TrayToolsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            TraySubheader(String(localized: "Tools")).padding(.leading, 6)
            tool("displays", "display.2", String(localized: "Displays and virtual displays")) {
                TrayRow(icon: "arrow.triangle.2.circlepath", title: model.busy ? String(localized: "Reconnecting…") : String(localized: "Reconnect all"),
                        enabled: !model.busy) { Task { await model.reconnectAll() } }
                TrayRow(icon: "arrow.clockwise", title: String(localized: "Detect displays")) { Task { await model.refresh() } }
                TrayRow(icon: "plus.rectangle.on.rectangle", title: String(localized: "Virtual displays…")) { ui.openSettings(.virtual) }
                TraySwitchRow(title: String(localized: "Keep displays awake while external connected"),
                              isOn: model.settings.preventDisplaySleepWithExternal) {
                    model.setPreventDisplaySleepWithExternal($0)
                }
                TraySwitchRow(title: String(localized: "Turn built-in off when an external connects"),
                              isOn: model.settings.autoDisconnectBuiltInOnExternal) {
                    model.setAutoDisconnectBuiltInOnExternal($0)
                }
            }
            tool("scenes", "square.stack.3d.up", String(localized: "Scenes")) {
                if model.scenes.isEmpty {
                    TrayNote(String(localized: "No saved scenes. A scene remembers the arrangement and modes of all displays."))
                }
                ForEach(model.scenes) { scene in
                    TrayRow(icon: "play.circle", title: scene.name) { Task { await model.applyScene(scene) } }
                }
                TrayRow(icon: "square.and.arrow.down", title: String(localized: "Save or edit scenes…")) { ui.openSettings(.scenes) }
            }
            TrayRow(icon: "rectangle.3.group", title: String(localized: "Display arrangement…")) { ui.openSettings(.arrange) }
            TrayRow(icon: "pip", title: String(localized: "Capture and Picture in Picture…")) { ui.openSettings(.capture) }
            TrayRow(icon: "cpu", title: String(localized: "EDID and HiDPI…")) { ui.openSettings(.advanced) }
            TrayRow(icon: "terminal", title: String(localized: "Automation and HTTP…")) { ui.openSettings(.automation) }
            TrayRow(icon: "keyboard", title: String(localized: "Hotkeys and diagnostics…")) { ui.openSettings(.health) }
            TrayRow(icon: "doc.zipper", title: String(localized: "Export diagnostics")) {
                Task {
                    if let url = await model.exportDiagnostics() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            let update = SoftwareUpdatePolicy.presentation(for: model.updatePhase)
            TrayRow(icon: update.systemImage, title: update.title.appLocalized, detail: update.badge,
                    enabled: !update.showsProgress) { model.checkForUpdates() }
        }
        .padding(.vertical, 4)
        .background(ODColor.fillQuaternary, in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder
    private func tool<Content: View>(_ id: String, _ icon: String, _ title: String,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        let isOpen = ui.openTools.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            TrayRow(icon: icon, title: title, disclosure: isOpen ? .open : .closed, identifier: "tray.tool.\(id)") {
                ui.toggle(\.openTools, id)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 1) { content() }
                    .padding(.leading, 10).padding(.bottom, 4)
                    .transition(.trayReveal)
            }
        }
        .clipped()
    }
}

private struct TrayButtonRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ui: TrayUIState

    var body: some View {
        HStack(spacing: 2) {
            Text(model.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .padding(.leading, 6)
            Spacer()
            TrayIconButton(symbol: ui.pinned ? "pin.fill" : "pin", active: ui.pinned,
                           help: ui.pinned ? String(localized: "Unpin: close on a click outside")
                                           : String(localized: "Pin: stay open on a click outside")) {
                ui.pinned.toggle()
            }
            TrayIconButton(symbol: "ellipsis.circle", active: ui.toolsOpen, help: String(localized: "Tools")) {
                withAnimation(TrayMotion.expand) { ui.toolsOpen.toggle() }
            }
            TrayIconButton(symbol: "gearshape", help: String(localized: "Settings (⌥-click the icon)")) { ui.openSettings() }
            TrayIconButton(symbol: "power", help: String(localized: "Quit OpenDisplay — brings back any displays it disconnected or mirrored")) {
                NSApp.terminate(nil)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Motion

/// One timing for everything that opens or closes in the tray. The panel host animates the window's
/// bottom edge with the same duration and curve (`TrayPanelController`), so the edge travels with
/// the content instead of snapping a frame later.
enum TrayMotion {
    static let duration: Double = 0.24
    static let expand = Animation.easeInOut(duration: duration)
}

extension AnyTransition {
    /// Content unfolding from under its header: fades in while sliding down from slightly above,
    /// clipped by the section so it never draws over the rows above it.
    static var trayReveal: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -10)),
                    removal: .opacity.combined(with: .offset(y: -6)))
    }
}

// MARK: - Controls

private func trayGlyph(_ displayClass: DisplayClass) -> String {
    switch displayClass {
    case .builtIn: return "laptopcomputer"
    case .television: return "tv"
    case .projector: return "videoprojector"
    case .sidecar: return "ipad.landscape"
    case .airplay: return "airplayvideo"
    case .virtual: return "rectangle.dashed"
    case .headlessAdapter: return "cable.connector"
    default: return "display"
    }
}

private struct TrayGlyph: View {
    let symbol: String
    let highlighted: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .frame(width: 28, height: 28)
            .background(highlighted ? ODColor.accent : ODColor.fillSecondary, in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .bottomTrailing) {
                if highlighted {
                    Text("M").font(.system(size: 8, weight: .heavy)).foregroundStyle(ODColor.accent)
                        .frame(width: 12, height: 12)
                        .background(Color.white, in: Circle())
                        .offset(x: 3, y: 3)
                }
            }
            .help(highlighted ? String(localized: "Main display (menu bar and Dock)") : "")
    }
}

private struct TrayTag: View {
    let text: String
    let tint: Color
    init(_ text: String, tint: Color) { self.text = text; self.tint = tint }

    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct TrayDivider: View {
    var body: some View { Rectangle().fill(ODColor.separator).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 3) }
}

private struct TraySubheader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.top, 6).padding(.bottom, 2).padding(.leading, 2)
    }
}

private struct TrayNote: View {
    let text: String
    var tint: Color = .secondary
    init(_ text: String, tint: Color = .secondary) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }
}

private struct TrayLabeled<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, value: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.value = value; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

private enum TrayDisclosure { case none, closed, open }

/// Full-width menu row with hover highlight: icon · title · detail · disclosure chevron.
private struct TrayRow: View {
    let icon: String
    var iconTint: Color = .secondary
    let title: String
    var detail: String?
    var disclosure: TrayDisclosure = .none
    var enabled = true
    var identifier: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12.5)).foregroundStyle(iconTint).frame(width: 18)
                Text(title).font(.system(size: 12.5)).foregroundStyle(enabled ? .primary : .secondary).lineLimit(1)
                Spacer(minLength: 6)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if disclosure != .none {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(disclosure == .open ? 90 : 0))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && enabled ? ODColor.rowHover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
        .accessibilityIdentifier(identifier ?? "tray.row")
    }
}

/// Selectable list row with a leading checkmark for the current value.
private struct TrayChoiceRow<Label: View>: View {
    let selected: Bool
    var enabled = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ODColor.accent).opacity(selected ? 1 : 0).frame(width: 12)
                label()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ODColor.accentTint : (hovering && enabled ? ODColor.rowHover : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tray.choice")
    }
}

private struct TrayCheckRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square").font(.system(size: 12))
                    .foregroundStyle(isOn ? ODColor.accent : Color.secondary)
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TraySwitchRow: View {
    let title: String
    var detail: String?
    let isOn: Bool
    var enabled = true
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12)).foregroundStyle(enabled ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 6)
            TraySwitch(isOn: isOn, enabled: enabled, onChange: onChange)
                .accessibilityLabel(title)
                .accessibilityIdentifier("tray.switch")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }
}

/// Custom switch: always drawn with the accent colour, even though the panel never activates the app
/// (standard controls in an inactive app turn grey).
private struct TraySwitch: View {
    let isOn: Bool
    var enabled = true
    let onChange: (Bool) -> Void

    var body: some View {
        Button { onChange(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? ODColor.accent : ODColor.fillPrimary)
                Circle().fill(Color.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 32, height: 18)
            .animation(.snappy(duration: 0.18), value: isOn)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

private struct TraySegmented<Value: Hashable>: View {
    let options: [(String, Value)]
    let selection: Value
    var enabled = true
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.1 == selection
                Button { if !selected { onSelect(option.1) } } label: {
                    Text(option.0).font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(selected ? ODColor.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(ODColor.fillTertiary, in: RoundedRectangle(cornerRadius: 8))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct TrayPillButton: View {
    let title: String
    var prominent = false
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, prominent: Bool = false, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.prominent = prominent; self.destructive = destructive; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: prominent || destructive ? .semibold : .regular))
                .foregroundStyle(prominent || destructive ? Color.white : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(fill, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityIdentifier("tray.pill")
    }

    private var fill: Color {
        if destructive { return ODColor.danger }
        if prominent { return ODColor.accent }
        return hovering ? ODColor.fillPrimary : ODColor.fillSecondary
    }
}

private struct TrayMiniButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.prominent = prominent; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 8).frame(height: 18)
                .background(prominent ? ODColor.accent : ODColor.fillSecondary, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("tray.mini")
    }
}

private struct TrayIconButton: View {
    let symbol: String
    var active = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
                .foregroundStyle(active ? ODColor.accent : Color.secondary)
                .frame(width: 28, height: 24)
                .background(hovering || active ? ODColor.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("tray.button.\(symbol)")
        .onHover { hovering = $0 }
    }
}

/// Control-Center-style slider: a thick track with the icon inside it. Writes continuously while
/// dragging (brightness/volume act live). No scroll-wheel binding: the wheel scrolls the panel.
private struct TraySlider: View {
    let value: Double
    let icon: String
    let valueText: String
    let accessibilityLabel: String
    var showsValue = true
    var leadingAction: (() -> Void)?
    let onChange: (Double) -> Void
    @State private var dragValue: Double?

    init(value: Double, icon: String, valueText: String, accessibilityLabel: String, showsValue: Bool = true,
         leadingAction: (() -> Void)? = nil, onChange: @escaping (Double) -> Void) {
        self.value = value; self.icon = icon; self.valueText = valueText
        self.accessibilityLabel = accessibilityLabel; self.showsValue = showsValue
        self.leadingAction = leadingAction; self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 8) {
            if let leadingAction {
                Button(action: leadingAction) {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
            }
            GeometryReader { geo in
                let shown = min(1, max(0, dragValue ?? value))
                ZStack(alignment: .leading) {
                    Capsule().fill(ODColor.fillSecondary)
                    Capsule().fill(ODColor.accent)
                        .frame(width: max(24, geo.size.width * shown))
                    if leadingAction == nil {
                        Image(systemName: icon).font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white)
                            .padding(.leading, 7)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let next = min(1, max(0, gesture.location.x / max(1, geo.size.width)))
                        dragValue = next
                        onChange(next)
                    }
                    .onEnded { _ in dragValue = nil })
            }
            .frame(height: 22)
            if showsValue {
                Text(valueText).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: 0...1) { Text(accessibilityLabel) }
        }
        .accessibilityIdentifier("tray.slider")
    }
}

/// Discrete variant for the resolution slider: snaps to stops, previews while dragging and commits
/// only on release (a mode change is expensive and confirmed separately).
private struct TrayStepSlider: View {
    let count: Int
    let index: Int
    let markers: [Int]
    let icon: String
    let valueText: String
    var enabled = true
    let onDrag: (Int?) -> Void
    let onCommit: (Int) -> Void
    @State private var dragIndex: Int?

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                let shown = dragIndex ?? index
                let fraction = count > 1 ? Double(shown) / Double(count - 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(ODColor.fillSecondary)
                    Capsule().fill(enabled ? ODColor.accent.opacity(0.85) : Color.gray.opacity(0.5))
                        .frame(width: max(24, 24 + (width - 24) * fraction))
                        .animation(.snappy(duration: 0.14), value: shown)
                    ForEach(0..<count, id: \.self) { stop in
                        Circle()
                            .fill(markers.contains(stop) ? ODColor.connected : Color.white.opacity(0.55))
                            .frame(width: markers.contains(stop) ? 5 : 3, height: markers.contains(stop) ? 5 : 3)
                            .position(x: 12 + (width - 24) * (count > 1 ? Double(stop) / Double(count - 1) : 0),
                                      y: 11)
                    }
                    Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.white)
                        .padding(.leading, 7)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled, count > 1 else { return }
                        let raw = (gesture.location.x - 12) / max(1, width - 24)
                        let next = Int((min(1, max(0, raw)) * Double(count - 1)).rounded())
                        if next != dragIndex { dragIndex = next; onDrag(next) }
                    }
                    .onEnded { _ in
                        guard enabled, let committed = dragIndex else { return }
                        dragIndex = nil
                        onDrag(nil)
                        onCommit(committed)
                    })
            }
            .frame(height: 22)
            Text(valueText).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
        }
        .opacity(enabled ? 1 : 0.6)
        .accessibilityElement()
        .accessibilityLabel("Resolution")
        .accessibilityValue(valueText)
    }
}

#endif
