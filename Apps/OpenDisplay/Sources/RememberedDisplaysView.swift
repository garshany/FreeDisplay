#if os(macOS)
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// Settings → Displays → Remembered (SD-09, FB-13): every display FreeDisplay keeps a record of —
/// connected, switched off by FreeDisplay, or only remembered — with an explicit, confirmed way to
/// forget one that isn't connected and to reset a connected one's saved settings.
///
/// Forgetting is about FreeDisplay's own records. It never disconnects anything, never writes to a
/// monitor and never touches macOS's display configuration, and the confirmation says so: a display
/// macOS still detects is offered a reset instead, because forgetting it would only rediscover it.
struct RememberedDisplaysView: View {
    @EnvironmentObject private var model: AppModel
    /// Opens a connected display's own settings.
    let onShowDisplay: (DisplayRecordID) -> Void
    @State private var pending: PendingCleanup?
    @State private var outcome: Outcome?
    @State private var identityEntry: RememberedDisplay?

    struct PendingCleanup: Identifiable {
        let id: String
        let mode: RememberedDisplayCleanup.Mode
    }

    struct Outcome: Equatable {
        let text: String
        let isProblem: Bool
    }

    var body: some View {
        let entries = model.rememberedDisplays
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: ODSpacing.md) {
                    Text("Every display FreeDisplay has a record of, including ones that aren’t connected now. A record holds the display’s name in FreeDisplay, favourite modes, menu settings, group memberships and protected layouts.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    RememberedDisplayRetentionEditor()
                    if let outcome {
                        ODInlineBanner(tone: outcome.isProblem ? .orange : .green,
                                       systemImage: outcome.isProblem ? "exclamationmark.triangle" : "checkmark.circle",
                                       title: outcome.text)
                    }
                    if entries.isEmpty {
                        Text("FreeDisplay doesn’t remember any displays yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ODCard {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { ODDivider() }
                                RememberedDisplayRow(
                                    entry: entry,
                                    focused: model.rememberedDisplayFocus == entry.id,
                                    onShow: { id in
                                        model.rememberedDisplayFocus = nil
                                        onShowDisplay(id)
                                    },
                                    onIdentity: { identityEntry = entry },
                                    onCleanup: {
                                        outcome = nil
                                        pending = PendingCleanup(id: entry.id, mode: entry.cleanupMode)
                                    })
                                .id(entry.id)
                            }
                        }
                    }
                    Text("Forgetting a display that isn’t connected removes FreeDisplay’s record of it; if it is connected again later, FreeDisplay treats it as a new display. A connected display can’t be forgotten — macOS would report it again at once — so it offers “Reset Settings…” instead. A display FreeDisplay switched off has to be reconnected first; if it doesn’t come back, it can be forgotten then. None of this sends anything to the monitor or changes macOS’s own display settings: “Factory reset” in the monitor controls is a different thing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(ODSpacing.lg)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: model.rememberedDisplayFocus, initial: true) { _, focus in
                guard let focus else { return }
                withAnimation { proxy.scrollTo(focus, anchor: .center) }
            }
        }
        .sheet(item: $identityEntry) { entry in
            VStack(alignment: .leading) {
                ScrollView { DisplayIdentityView(entryID: entry.id).padding(24) }
                HStack { Spacer(); Button("Close") { identityEntry = nil }.keyboardShortcut(.cancelAction) }.padding()
            }.frame(width: 650, height: 650).environmentObject(model)
        }
        .sheet(item: $pending) { request in
            RememberedDisplayCleanupSheet(request: request) { result in
                pending = nil
                outcome = result
            }
            .environmentObject(model)
        }
    }
}

private struct RememberedDisplayRetentionEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var days = ""
    @State private var confirm = false

    private var parsed: Int? { Int(days) }
    private var valid: Bool { days.isEmpty || parsed.map { $0 > 0 } == true }
    private var due: [RememberedDisplay] {
        RememberedDisplayRetention.dueEntries(model.rememberedDisplays, days: parsed, now: Date())
    }

    var body: some View {
        ODCard(title: String(localized: "Remember offline displays")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Automatic forgetting is off by default. Leave the field empty to keep records until you explicitly forget them. A positive whole number uses elapsed days since last seen. Connected, ambiguous, virtual and app-switched-off records are exempt.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Identification for new records", selection: Binding(
                    get: { model.settings.newDisplayIdentityStrategy },
                    set: { model.setNewDisplayIdentityStrategy($0) })) {
                    ForEach(DisplayIdentityStrategy.allCases, id: \.self) { strategy in
                        Text(identityLabel(strategy.rawValue)).tag(strategy)
                    }
                }
                Text("The default identification strategy applies only to newly created records. Existing records keep their strategy.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Retention (days; empty means off)", text: $days).textFieldStyle(.roundedBorder)
                    Button("Review retention…") { confirm = true }.disabled(!valid || model.busy)
                }
            }.padding(12)
        }
        .onAppear { days = model.settings.rememberedDisplayRetentionDays.map(String.init) ?? "" }
        .sheet(isPresented: $confirm) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Confirm automatic forgetting").font(.headline)
                Text("This preference may forget eligible records immediately and on later display-list updates. Forgetting removes their saved app preferences, group membership and protected layouts. It does not disconnect hardware. Cancel keeps the current policy.")
                Text("Records due now:").font(.subheadline.bold())
                ScrollView {
                    if due.isEmpty { Text("None") }
                    ForEach(due) { Text(model.rememberedName(of: $0)) }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { confirm = false }.keyboardShortcut(.cancelAction)
                    Button("Apply retention policy") {
                        let chosen = parsed
                        confirm = false
                        Task { await model.setRememberedDisplayRetention(days: chosen) }
                    }.disabled(model.busy)
                }
            }.padding(24).frame(width: 520, height: 400)
        }
    }
}

private struct RememberedDisplayRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: RememberedDisplay
    let focused: Bool
    let onShow: (DisplayRecordID) -> Void
    let onIdentity: () -> Void
    let onCleanup: () -> Void
    @State private var showingReport = false

    private var live: DisplayObservation? {
        model.displays.first { entry.observationIDs.contains($0.recordID) }
    }

    var body: some View {
        let name = model.rememberedName(of: entry)
        ODRow(name, secondary: secondary, selected: focused) {
            Image(systemName: model.menuIconSymbol(for: entry.observationIDs) ?? trayGlyph(model.rememberedClass(of: entry)))
                .font(.system(size: 15)).frame(width: 24)
                .foregroundStyle(entry.isConnected ? Color.primary : Color.secondary)
        } trailing: {
            HStack(spacing: 8) {
                statusBadge
                Button("Identity…", action: onIdentity).controlSize(.small)
                Button("Show Report…") { showingReport = true }.controlSize(.small)
                if let live {
                    Button("Settings") { onShow(live.recordID) }.controlSize(.small)
                }
                // Also for a display that is still enumerated because mirroring keeps it in the list.
                // A lit display with a ledger entry under the disconnect method is one macOS relit
                // during a wake: its "off" is still owed, and "Reconnect" would only cancel that.
                if let offline = entry.offline, entry.isTurnedOffByApp || model.logicalOffMethod == .mirror {
                    Button(model.logicalOffMethod == .mirror ? String(localized: "Stop Mirroring")
                                                             : String(localized: "Reconnect")) {
                        Task { await model.reconnectOffline(offline) }
                    }
                    .controlSize(.small).disabled(model.busy)
                }
                Button(entry.cleanupMode == .forget ? String(localized: "Forget…") : String(localized: "Reset Settings…"),
                       role: .destructive) { onCleanup() }
                    .controlSize(.small).disabled(model.busy || forgetBlocked)
                    .help(cleanupHelp)
            }
        }
        .sheet(isPresented: $showingReport) {
            DisplayInformationReportSheet(remembered: entry).environmentObject(model)
        }
    }

    /// Forget isn't offered while FreeDisplay still owes the display its way back.
    private var forgetBlocked: Bool {
        entry.cleanupMode == .forget && entry.forgetRefusal != nil
    }

    private var cleanupHelp: String {
        switch (entry.cleanupMode, entry.forgetRefusal) {
        case (.reset, _):
            return String(localized: "Clear what FreeDisplay saved for this display; it stays connected and recognized")
        case (.forget, .turnedOffByApp?):
            return String(localized: "FreeDisplay switched this display off and still owes it a way back. Reconnect it first; if it doesn’t come back, it can be forgotten.")
        case (.forget, .builtInTurnedOff?):
            return String(localized: "The built-in display can’t be forgotten while FreeDisplay has it switched off: this record is how it is turned back on.")
        default:
            return String(localized: "Remove FreeDisplay’s record of this display")
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch entry.status {
        case .connected:
            if entry.offline != nil, model.logicalOffMethod == .mirror {
                ODBadge(String(localized: "Mirrored by FreeDisplay"), tone: .accent)
            } else {
                ODBadge(String(localized: "Connected"), tone: .green)
            }
        case .turnedOff:
            ODBadge(model.logicalOffMethod == .mirror ? String(localized: "Mirrored by FreeDisplay")
                                                      : String(localized: "Turned off by FreeDisplay"), tone: .accent)
        case .reconnectFailed: ODBadge(String(localized: "Didn’t reconnect"), tone: .orange)
        case .notConnected: ODBadge(String(localized: "Not connected"))
        }
    }

    /// Model name when the row shows an alias, and when the display was last seen.
    private var secondary: String? {
        var parts: [String] = []
        if let alias = entry.record?.alias, !alias.isEmpty,
           let model = entry.record?.fingerprint.modelName, !model.isEmpty, model != alias {
            parts.append(model)
        }
        if !entry.isConnected, let seen = entry.record?.lastSeen {
            let date = seen.formatted(date: .abbreviated, time: .shortened)
            parts.append(String(localized: "last seen \(date)"))
        }
        if entry.record?.isProvisional == true {
            parts.append(String(localized: "not told apart from a similar display yet"))
        }
        switch model.retentionVerdict(for: entry) {
        case .off: break
        case .exempt: parts.append(String(localized: "kept while this record is protected from automatic forgetting"))
        case .keptUntil(let date):
            let formatted = date.formatted(date: .abbreviated, time: .omitted)
            parts.append(String(localized: "kept until at least \(formatted)"))
        case .due: parts.append(String(localized: "due for automatic forgetting"))
        }
        if entry.mayBeConnectedDisplay {
            parts.append(String(localized: "may be the connected look-alike"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The confirmation: names exactly what goes and what stays, before anything changes. Cancel leaves
/// every store untouched.
private struct RememberedDisplayCleanupSheet: View {
    @EnvironmentObject private var model: AppModel
    let request: RememberedDisplaysView.PendingCleanup
    let onFinish: (RememberedDisplaysView.Outcome?) -> Void
    @State private var working = false
    /// What the sheet showed when the user confirmed. Drawn instead of the live state while the
    /// action runs, so the sheet doesn't change (or blank out) under the user mid-operation.
    @State private var frozen: Snapshot?

    struct Snapshot {
        let entry: RememberedDisplay
        let plan: RememberedDisplayCleanup.Plan
        let name: String
    }

    var body: some View {
        let live = model.rememberedDisplays.first { $0.id == request.id }
        let shown = frozen ?? live.flatMap { entry in
            model.cleanupPlan(for: entry).map { Snapshot(entry: entry, plan: $0, name: model.rememberedName(of: entry)) }
        }
        VStack(alignment: .leading, spacing: ODSpacing.md) {
            if let shown {
                content(shown)
            } else {
                // Gone, or — if its state changed while the sheet was open — no longer forgettable.
                Text(live == nil ? String(localized: "This display is no longer remembered.")
                                 : String(localized: "This display can’t be forgotten right now."))
                    .font(.headline)
                HStack {
                    Spacer()
                    Button("Close") { onFinish(nil) }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(ODSpacing.xl)
        .frame(width: 500)
    }

    @ViewBuilder
    private func content(_ shown: Snapshot) -> some View {
        let entry = shown.entry
        let plan = shown.plan
        let name = shown.name
        // The display came (or went) while the sheet was open: what was asked for no longer applies.
        let changed = frozen == nil && entry.cleanupMode != request.mode
        Text(request.mode == .forget ? String(localized: "Forget “\(name)”?")
                                     : String(localized: "Reset FreeDisplay’s settings for “\(name)”?"))
            .font(.headline)
        if changed {
            ODInlineBanner(tone: .orange, systemImage: "exclamationmark.triangle",
                           title: request.mode == .forget
                               ? String(localized: "This display is connected now, so it can’t be forgotten. Close this and use “Reset Settings…” instead.")
                               : String(localized: "This display is no longer connected. Close this and use “Forget…” instead."))
        }
        if request.mode == .forget, plan.removesTurnedOffRecord {
            ODInlineBanner(tone: .red, systemImage: "exclamationmark.octagon",
                           title: model.logicalOffMethod == .mirror
                               ? String(localized: "FreeDisplay mirrored this display and this record is how it undoes that")
                               : String(localized: "FreeDisplay turned this display off and this record is how it turns it back on"),
                           message: String(localized: "Its last reconnect found no display. After forgetting, its card leaves the menu, and neither Reconnect All nor quitting FreeDisplay will bring it back. If it is in fact still attached and switched off, it may stay dark until you unplug it and plug it in again, or restart the Mac. If the monitor is no longer connected, forgetting only removes the card."))
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Removes").font(.subheadline.weight(.semibold))
            ForEach(removals(plan), id: \.self) { bullet($0) }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("TV endpoints, pairing and remote preferences stay on this Mac under their original display identifiers. They are excluded from settings archives, app reset, per-display Forget or Reset, and transfer. Use TV control to disable a controller or delete its local pairing; device-side authorization is unchanged.")
            Text("Keeps").font(.subheadline.weight(.semibold))
            ForEach(kept(plan), id: \.self) { bullet($0) }
            Text("Integration actions and hooks stay under their original identifiers, including after Forget or Reset. They may contain device-specific executable arguments or URLs. Review or remove them in Actions & Hooks; transfer never retargets them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            if working { ProgressView().controlSize(.small) }
            Spacer()
            // Once confirmed, the change is under way: Cancel would only hide it, not stop it.
            Button("Cancel") { onFinish(nil) }.keyboardShortcut(.cancelAction).disabled(working)
            Button(request.mode == .forget ? String(localized: "Forget Display") : String(localized: "Reset Settings"),
                   role: .destructive) {
                frozen = shown
                working = true
                Task {
                    let result = await model.performCleanup(of: request.id, confirmed: request.mode)
                    working = false
                    onFinish(outcomeText(result, name: name))
                }
            }
            .disabled(changed || working || model.busy)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func removals(_ plan: RememberedDisplayCleanup.Plan) -> [String] {
        var items: [String] = []
        if plan.mode == .forget {
            items.append(plan.registryRecordID == nil
                         ? String(localized: "What FreeDisplay saved under this display’s id")
                         : String(localized: "Its record: how FreeDisplay recognizes this display, and the name it shows"))
        } else if plan.alias != nil || plan.tagCount > 0 {
            items.append(plan.alias.map { alias in String(localized: "Its name in FreeDisplay (“\(alias)”) and tags") }
                         ?? String(localized: "Its tags"))
        }
        if plan.mode == .forget, let alias = plan.alias {
            items.append(String(localized: "The name “\(alias)”"))
        }
        if plan.favoriteModeCount > 0 { items.append(String(localized: "Favourite modes: \(plan.favoriteModeCount)")) }
        if !plan.groupNames.isEmpty {
            let groups = plan.groupNames.joined(separator: ", ")
            items.append(String(localized: "Membership in groups: \(groups)"))
        }
        for key in plan.protectedLayoutKeys {
            let members = model.settings.protectedLayouts[key].map(LayoutProtectionPolicy.members(of:)) ?? []
            let names = members.map { model.rememberedDisplayName(for: $0) }.sorted().joined(separator: " + ")
            items.append(String(localized: "The protected layout for \(names)"))
        }
        if plan.hasMenuPreferences { items.append(String(localized: "Its menu settings: hidden or not, icon, position")) }
        if plan.softwareBrightness { items.append(String(localized: "Using software brightness instead of DDC")) }
        if plan.appleDDCOverride { items.append(String(localized: "Allowing DDC on this Apple display")) }
        if plan.ddcChannelMapping { items.append(String(localized: "Its manually confirmed DDC channel mapping")) }
        if plan.defaultGroupOffset { items.append(String(localized: "Its Default group brightness offset")) }
        if plan.luminanceAnchors { items.append(String(localized: "Its saved luminance anchors")) }
        if plan.clockRecipeCount > 0 {
            items.append(String(localized: "Its Clock Mode recipes: \(plan.clockRecipeCount)"))
        }
        if plan.volumeFeedback { items.append(String(localized: "Its volume and mute feedback preference")) }
        if plan.adaptiveOffset { items.append(String(localized: "Adaptive Display’s learned brightness offset")) }
        if plan.keepsDisplaysAwake { items.append(String(localized: "Keeping the displays awake while it is connected")) }
        if plan.keyboardAudioPreferences {
            items.append(String(localized: "Its keyboard and sound settings: key control, matching output, sound output"))
        }
        if plan.removesTurnedOffRecord {
            items.append(String(localized: "The record that it is switched off, and its card in the menu"))
        }
        if items.isEmpty { items.append(String(localized: "Nothing else is saved for this display")) }
        return items
    }

    private func kept(_ plan: RememberedDisplayCleanup.Plan) -> [String] {
        var items: [String] = []
        if plan.mode == .reset {
            items.append(String(localized: "The display stays connected and FreeDisplay keeps recognizing it"))
            if model.managedOffline.contains(where: { plan.observationIDs.contains($0.recordID) }) {
                items.append(String(localized: "The record that FreeDisplay switched it off"))
            }
        }
        for restore in plan.keptRestores {
            switch restore {
            case .faceLight:
                items.append(String(localized: "FaceLight’s pending restore of the monitor’s brightness"))
            case .appPreset:
                items.append(String(localized: "An app preset’s pending restore of the monitor’s values"))
            case .eveningColorPreset:
                items.append(String(localized: "Adaptive Display’s pending return to the day colour preset"))
            }
        }
        // The user's own rules aimed at this display stay where they were made.
        if plan.keptInputSwitchHotkeys > 0 {
            items.append(String(localized: "Input hotkeys for it: \(plan.keptInputSwitchHotkeys) — edit them under Diagnostics → Input hotkeys"))
        }
        if !plan.keptAppPresetNames.isEmpty {
            let names = plan.keptAppPresetNames.joined(separator: ", ")
            items.append(String(localized: "App presets aimed at it: \(names)"))
        }
        items.append(String(localized: "Scenes, the monitor’s own settings, and macOS’s display settings, colour profiles and modes — nothing is sent to the monitor"))
        return items
    }

    private func outcomeText(_ result: AppModel.RememberedDisplayCleanupOutcome,
                             name: String) -> RememberedDisplaysView.Outcome {
        switch result {
        case .done:
            return .init(text: request.mode == .forget ? String(localized: "“\(name)” was forgotten.")
                                                       : String(localized: "FreeDisplay’s settings for “\(name)” were reset."),
                         isProblem: false)
        case .stateChanged:
            return .init(text: String(localized: "Nothing was changed: “\(name)” was connected or disconnected meanwhile."),
                         isProblem: true)
        case .refused:
            return .init(text: String(localized: "Nothing was changed: FreeDisplay still has “\(name)” switched off. Reconnect it first."),
                         isProblem: true)
        case .notFound:
            return .init(text: String(localized: "Nothing was changed: “\(name)” is no longer remembered."), isProblem: true)
        }
    }
}
#endif
