// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// Settings for feedback (SO-35, SO-04, IN-16, TR-17): OpenDisplay's own HUD — its switches, look,
/// place and screen, interaction — the published events, and receiver apps taking them over. What
/// is delivered where is always said in words (`OSDFeedbackPolicy.delivery`), so "External HUD only"
/// never hides that nothing is listening and two HUDs are never on without a word about duplicates.
struct OSDSettingsRows: View {
    @EnvironmentObject private var model: AppModel

    private var feedback: OSDFeedbackSettings { model.settings.osdFeedback }
    private var drawsLocally: Bool {
        model.settings.osdStyle != .external && (model.settings.osdEnabled || feedback.showsCustomFeedback)
    }

    var body: some View {
        Text("On-screen display").font(.title3)
        Toggle(isOn: Binding(get: { model.settings.osdEnabled }, set: { model.setOSDEnabled($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show an on-screen display for brightness & volume")
                Text("Confirms a brightness, volume or mute change made with the keys or a keyboard shortcut. Sliders show their own value and draw none.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Toggle(isOn: Binding(get: { feedback.showsCustomFeedback },
                             set: { value in model.updateOSDFeedback { $0.showsCustomFeedback = value } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show other feedback")
                Text("Confirms an input switch made with an input hotkey. Independent of the switch above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if model.settings.osdEnabled || feedback.showsCustomFeedback {
            appearanceRows.padding(.leading, ODSpacing.lg)
        }
        deliveryStatus
        Toggle(isOn: Binding(
            get: { model.settings.publishOSDEventsEnabled },
            set: { model.setPublishOSDEventsEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Broadcast display events for notch / external HUD apps")
                Text("Publishes each brightness, volume, mute and input change FreeDisplay makes — including slider, display-group, HTTP, command-line and Shortcuts changes — over the dev.opendisplay.osd distributed notification, whether or not FreeDisplay shows its own HUD. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        volumeRows
        receiverRows
    }

    // MARK: Look and place

    @ViewBuilder private var appearanceRows: some View {
        HStack {
            // FA-05: every local style is drawn by OpenDisplay. "Native" read as the macOS system
            // HUD, which this build doesn't use.
            Picker("Style", selection: Binding(get: { model.settings.osdStyle }, set: { model.setOSDStyle($0) })) {
                Text("Standard").tag(OSDStyle.native)
                Text("Minimal").tag(OSDStyle.minimal)
                Text("Classic").tag(OSDStyle.classicTahoe)
                Text("External HUD only").tag(OSDStyle.external)
            }
            .fixedSize()
            Picker("Position", selection: Binding(get: { model.settings.osdPosition }, set: { model.setOSDPosition($0) })) {
                Text("Bottom").tag(OSDPosition.bottomCenter)
                Text("Top").tag(OSDPosition.topCenter)
                Text("Center").tag(OSDPosition.center)
                Text("Top corner").tag(OSDPosition.topTrailing)
                Text("Under the menu bar icon").tag(OSDPosition.underMenuBarIcon)
                Text("Under the menu bar").tag(OSDPosition.underMenuBar)
            }
            .fixedSize()
        }
        Picker("Screen", selection: Binding(get: { feedback.screen },
                                            set: { value in model.updateOSDFeedback { $0.screen = value } })) {
            Text("The display that changed").tag(OSDScreenChoice.affectedDisplay)
            Text("The screen with the pointer").tag(OSDScreenChoice.pointer)
            Text("The screen with the focused window").tag(OSDScreenChoice.focused)
            Text("The primary display (with the menu bar)").tag(OSDScreenChoice.primary)
        }
        .fixedSize()
        if model.settings.osdPosition == .underMenuBarIcon {
            Text("Under the menu bar icon appears on the icon’s screen. The screen choice applies when macOS isn’t showing the icon; it then appears in the top corner.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.settings.osdPosition.isMenuBarAnchored {
            Text("While the FreeDisplay menu is open, this position shows nothing — the menu is in the way. The change itself still happens.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Show the level as a number", isOn: Binding(
            get: { feedback.showsValue }, set: { value in model.updateOSDFeedback { $0.showsValue = value } }))
        Toggle("Segmented bar", isOn: Binding(
            get: { feedback.segmentedBar }, set: { value in model.updateOSDFeedback { $0.segmentedBar = value } }))
        Toggle("Rounded layout", isOn: Binding(
            get: { feedback.rounded }, set: { value in model.updateOSDFeedback { $0.rounded = value } }))
        Toggle("Adaptive background", isOn: Binding(
            get: { feedback.adaptiveBackground }, set: { value in model.updateOSDFeedback { $0.adaptiveBackground = value } }))
        Toggle("Show shadow", isOn: Binding(
            get: { feedback.shadow }, set: { value in model.updateOSDFeedback { $0.shadow = value } }))
        Toggle("Play a sound after adjusting volume in the HUD", isOn: Binding(
            get: { feedback.volumeCompletionSound },
            set: { value in model.updateOSDFeedback { $0.volumeCompletionSound = value } }))
        Toggle(isOn: Binding(get: { feedback.interactive },
                             set: { value in model.updateOSDFeedback { $0.interactive = value } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Let the pointer use the on-screen display")
                Text("Moving the pointer onto it keeps it up, and dragging its bar or clicking an end icon adjusts the level; hold Shift to change only that display, not its group. Off, it lets every click through to the window beneath.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Text("FreeDisplay draws every style itself; none of them is the macOS system HUD. A level shown for a monitor’s hardware is the one requested; if the monitor reports something else, or doesn’t answer, the HUD says it isn’t confirmed.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text("Values are percentages of the control’s range. FreeDisplay has no calibrated luminance value to show in nits.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Where feedback goes

    @ViewBuilder private var deliveryStatus: some View {
        switch OSDFeedbackPolicy.delivery(model.settings) {
        case .externalOnlyWithoutDispatch:
            // SO-04: "External HUD only" hides this HUD so another app can draw it, which needs the
            // broadcast. Without it nothing shows at all — say so, and offer the one switch that
            // fixes it rather than flipping it behind the user's back.
            ODInlineBanner(tone: .orange, systemImage: "exclamationmark.triangle",
                           title: String(localized: "No feedback is shown"),
                           message: String(localized: "“External HUD only” hides FreeDisplay’s HUD, and broadcasting is off, so no app receives the changes either.")) {
                Button("Turn On Broadcasting") { model.setPublishOSDEventsEnabled(true) }
            }
        case .externalOnly:
            Label("External HUD only: FreeDisplay draws nothing and publishes each change for another app to draw. Nothing tells FreeDisplay whether an app is listening.",
                  systemImage: "dot.radiowaves.left.and.right")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .localAndPublished:
            ODInlineBanner(tone: .orange, systemImage: "rectangle.on.rectangle",
                           title: String(localized: "Feedback may appear twice"),
                           message: String(localized: "FreeDisplay shows its own HUD and also publishes each change. An app that draws its own HUD from these events shows the same change a second time, unless one of the two is off.")) {
                Button("Use External HUD Only") { model.setOSDStyle(.external) }
            }
        case .localOnly, .publishedOnly, .none:
            EmptyView()
        }
    }

    // MARK: Per-display volume

    private var soundDisplays: [DisplayObservation] {
        model.displays.filter { $0.displayClass != .builtIn && $0.isActive }
    }

    @ViewBuilder private var volumeRows: some View {
        if model.settings.osdEnabled, drawsLocally, !soundDisplays.isEmpty {
            Text("Volume feedback per display").font(.headline)
            ForEach(soundDisplays, id: \.recordID) { display in
                Toggle(String(localized: "Show volume and mute for \(model.displayName(for: display))"), isOn: Binding(
                    get: { model.settings.showsVolumeFeedback(for: display.recordID) },
                    set: { show in
                        model.setShowsVolumeFeedback(show, for: display.recordID)
                    }))
            }
            Text("Off hides FreeDisplay’s HUD for that monitor’s volume and mute only; the keys still work and the change is still published.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Receiver apps (IN-16)

    @ViewBuilder private var receiverRows: some View {
        Toggle(isOn: Binding(get: { feedback.receiverHandshakeEnabled },
                             set: { value in model.updateOSDFeedback { $0.receiverHandshakeEnabled = value } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Let HUD apps take over these settings")
                Text("An app that draws its own HUD may ask FreeDisplay to publish events and hide its HUD, and gives your settings back when it is done. Any app on this Mac can ask. Off, such requests are answered “not allowed” and change nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let claim = feedback.receiverClaim {
            ODInlineBanner(tone: .accent, systemImage: "rectangle.portrait.and.arrow.right",
                           title: String(localized: "“\(claim.receiver)” has taken over feedback"),
                           message: String(localized: "It switched events on and turned off the HUDs it replaces. If it has quit without giving your settings back, restore them here; anything you changed since stays as you set it.")) {
                Button("Restore My Settings") { model.restoreOSDSettingsFromReceiver() }
            }
        }
    }
}
#endif
