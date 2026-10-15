#if os(macOS)
import DisplayDomain
import SwiftUI
import TopologyCore

struct DisplaySettingsTransferSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var plan: DisplaySettingsTransfer.Plan
    let onFinish: (String?) -> Void
    @State private var selection: Set<DisplaySettingsTransfer.Category>
    @State private var acknowledged = false
    @State private var working = false
    @State private var error: String?

    init(plan: DisplaySettingsTransfer.Plan, onFinish: @escaping (String?) -> Void) {
        _plan = State(initialValue: plan)
        self.onFinish = onFinish
        _selection = State(initialValue: plan.defaultSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.kind == .transfer ? "Confirm settings transfer" : "Confirm settings migration").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Source identifiers").font(.subheadline.bold())
                    Text(verbatim: plan.sourceIDs.map(\.rawValue).joined(separator: ", "))
                    Text("Destination identifier").font(.subheadline.bold())
                    Text(verbatim: plan.destinationLiveID.rawValue)
                    if plan.kind == .transfer {
                        Text("The source record will be forgotten, including unselected saved preferences. Selected destination values are replaced, including replacement with an empty value. The destination keeps its physical identity. This cannot be undone here.")
                    } else {
                        Text("Selected values move to the current identifier. Existing destination values win conflicts. Favourite modes are combined without duplicates. The record keeps its identity.")
                    }
                    if plan.kind == .migrate, plan.sourceIDs.count > 1 {
                        Picker("Migration source", selection: Binding(
                            get: { plan.migrationSourceID?.rawValue ?? "" },
                            set: { raw in
                                let id = raw.isEmpty ? nil : DisplayRecordID(rawValue: raw)
                                if let updated = model.selectingMigrationSource(id, in: plan) {
                                    plan = updated
                                    selection = updated.defaultSelection
                                }
                            })) {
                            Text("All nonconflicting sources").tag("")
                            ForEach(plan.sourceIDs, id: \.self) { id in
                                Text(verbatim: id.rawValue).tag(id.rawValue)
                            }
                        }
                        Text("Conflicting earlier values stay saved until you choose their source explicitly. Only values copied from the selected source are cleared.")
                    }
                    ForEach(plan.changes, id: \.category) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            if change.effect == .conflict {
                                Text(identityLabel(change.category.rawValue) + " · " + String(localized: "Conflict: both values stay where they are"))
                            } else {
                                Toggle(identityLabel(change.category.rawValue), isOn: Binding(
                                    get: { selection.contains(change.category) },
                                    set: { if $0 { selection.insert(change.category) } else { selection.remove(change.category) } }))
                            }
                            LabeledContent("Source", value: value(change.category, in: plan.source))
                            LabeledContent("Destination", value: value(change.category, in: plan.destination))
                        }
                    }
                    DisclosureGroup("Every saved identifier and relationship") {
                        identifierValues(plan.sourceIDs, snapshots: plan.sourceByID)
                        identifierValues(plan.destinationIDs, snapshots: plan.destinationByID)
                    }
                    Text("Safety permissions and relationships").font(.subheadline.bold())
                    ForEach(plan.retained, id: \.self) { retained in
                        Text(identityLabel(retained.rawValue))
                    }
                    if plan.kind == .transfer, let cleanup = plan.sourceCleanup {
                        Text("Removed with the source record").font(.subheadline.bold())
                        ForEach(cleanup.groupNames, id: \.self) { Text(verbatim: $0) }
                        ForEach(cleanup.protectedLayoutKeys, id: \.self) { Text(verbatim: $0) }
                        Text("The source alias, tags, favourites, menu presentation, brightness preferences, Default group offset, luminance anchors, keyboard and audio preferences, keep-awake request, volume feedback preference, Apple DDC permission and paired channel are removed. Pending restores, input hotkeys, app presets and scenes remain under their original identifiers; review them separately.")
                        if cleanup.removesTurnedOffRecord {
                            Text("The source has a failed reconnect record. Forgetting removes its recovery card too; if it is still attached and dark, unplug/replug or restart may be necessary.")
                        }
                    }
                    Text("Integration actions and hooks stay under their original identifiers, including after Forget or Reset. They may contain device-specific executable arguments or URLs. Review or remove them in Actions & Hooks; transfer never retargets them.")
                    Text("TV endpoints, pairing and remote preferences stay on this Mac under their original display identifiers. They are excluded from settings archives, app reset, per-display Forget or Reset, and transfer. Use TV control to disable a controller or delete its local pairing; device-side authorization is unchanged.")
                    Text("No monitor settings, macOS modes or colour profiles are written by this transfer.")
                    if plan.needsDifferentDisplayAcknowledgement {
                        Toggle("I am replacing a different physical display", isOn: $acknowledged)
                    } else if plan.physicalIdentity == .undetermined {
                        Text("Identity evidence cannot prove these are the same physical monitor. Confirm only after checking the UUIDs and physical displays.")
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }.font(.callout).textSelection(.enabled)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { onFinish(nil) }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Confirm", role: plan.kind == .transfer ? .destructive : nil) {
                    working = true
                    Task {
                        let result = await model.performSettingsTransfer(plan, selection: selection,
                            acknowledgedDifferentDisplays: acknowledged)
                        working = false
                        if result == .done { onFinish(String(localized: "The selected settings were moved.")) }
                        else if case .persistenceFailed(let path, let restored) = result {
                            let message = restored
                                ? String(localized: "Saving the transfer failed. Previous settings were restored.")
                                : String(localized: "Saving and rollback failed. Restore the retained recovery snapshot before continuing.")
                            error = path.map { message + "\n" + $0 } ?? message
                        }
                        else { error = String(localized: "Nothing was transferred. The preview or identity changed; close this sheet and review a new preview.") }
                    }
                }.disabled(working || model.busy || selection.isEmpty || (plan.needsDifferentDisplayAcknowledgement && !acknowledged))
            }
        }.padding(24).frame(width: 620, height: 640)
    }

    private func identifierValues(_ ids: [DisplayRecordID], snapshots: [DisplayRecordID: DisplaySettingsTransfer.SavedSettings]) -> some View {
        ForEach(ids, id: \.self) { id in
            if let saved = snapshots[id] {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: id.rawValue).bold()
                    ForEach(DisplaySettingsTransfer.Category.allCases.filter { $0 != .name && $0 != .tags }, id: \.self) { category in
                        LabeledContent(identityLabel(category.rawValue), value: value(category, in: saved))
                    }
                    ForEach(saved.protectedLayoutKeys, id: \.self) { Text(verbatim: $0) }
                    ForEach(DisplaySettingsTransfer.Retained.allCases.filter(saved.holds), id: \.self) {
                        Text(identityLabel($0.rawValue))
                    }
                }.font(.caption)
            }
        }
    }

    private func state(_ enabled: Bool) -> String {
        enabled ? String(localized: "Enabled") : String(localized: "Disabled")
    }

    private func value(_ category: DisplaySettingsTransfer.Category, in saved: DisplaySettingsTransfer.SavedSettings) -> String {
        switch category {
        case .name: return saved.alias ?? String(localized: "None")
        case .tags: return saved.tags.sorted().joined(separator: ", ")
        case .favoriteModes: return saved.favoriteKeys.joined(separator: ", ")
        case .menuPresentation:
            let visibility = saved.menuHidden ? String(localized: "Hidden") : String(localized: "Visible")
            return "\(visibility) · \(saved.menuIcon ?? "—") · \(saved.menuOrderPosition.map(String.init) ?? "—")"
        case .groupMembership: return saved.group.map { "\($0.groupName) · \($0.offset.map { String($0) } ?? "—")" } ?? String(localized: "None")
        case .softwareBrightness: return saved.softwareBrightness ? String(localized: "Enabled") : String(localized: "Disabled")
        case .adaptiveOffset: return saved.adaptiveOffset.map { String($0) } ?? String(localized: "None")
        case .defaultGroupOffset: return saved.defaultGroupOffset.map { String($0) } ?? String(localized: "None")
        case .keepAwake: return state(saved.keepAwake)
        case .volumeFeedback: return saved.volumeFeedback ? String(localized: "Hidden") : String(localized: "Visible")
        case .luminanceAnchors:
            guard let anchors = saved.luminanceAnchors else { return String(localized: "None") }
            let l = ReportLocalizer.app
            let values = LuminanceAnchor.allCases.compactMap { anchor -> String? in
                guard let value = anchors.overrides[anchor] else { return nil }
                return "\(LuminanceReport.anchorName(anchor, l)): \(value.nits) cd/m² · \(LuminanceReport.provenanceText(.manual(value.basis), l))"
            }
            return ([state(anchors.manualValuesEnabled)] + values).joined(separator: "; ")
        case .keyboardAudio:
            guard let audio = saved.keyboardAudio else { return String(localized: "None") }
            let keys = state(audio.keyboardControl), native = state(audio.nativeAudioEnabled), hud = state(audio.showsVolumeOSD)
            let match = audio.audioMatch ?? String(localized: "Automatic")
            let device = audio.nativeAudioDevice ?? String(localized: "None")
            return String(localized: "Keyboard: \(keys); matching output: \(match); native audio: \(native); sound output: \(device); volume HUD: \(hud)")
        }
    }
}
#endif
