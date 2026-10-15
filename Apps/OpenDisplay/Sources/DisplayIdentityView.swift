#if os(macOS)
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// The same read-only identity view is available for present and retained offline records.
struct DisplayIdentityView: View {
    @EnvironmentObject private var model: AppModel
    let entryID: String
    @State private var transfer: DisplaySettingsTransfer.Plan?
    @State private var outcome: String?
    @State private var strategyChoice: DisplayIdentityStrategy?

    private var entry: RememberedDisplay? { model.rememberedDisplays.first { $0.id == entryID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry {
                Text(model.rememberedName(of: entry)).font(.headline)
                Text("FreeDisplay keeps app record IDs, macOS UUIDs and temporary numeric display IDs separate. Names do not prove physical identity. Conflicting or ambiguous identity never silently joins two displays.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Recognition uses qualified vendor/model/serial first, then the same-Mac UUID, then a unique fingerprint score. A tie requires an explicit choice. A changed UUID can leave preferences under an earlier identifier; migration is always previewed.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("App record", value: entry.record?.id.rawValue ?? entry.id)
                LabeledContent("macOS UUIDs", value: entry.observationIDs.compactMap(\.cgUUID).joined(separator: ", "))
                if let record = entry.record {
                    Picker("Identification strategy", selection: Binding(
                        get: { record.identityStrategy ?? .automatic },
                        set: { strategyChoice = $0 })) {
                        ForEach(DisplayIdentityStrategy.allCases, id: \.self) { strategy in
                            Text(identityLabel(strategy.rawValue)).tag(strategy)
                        }
                    }
                    fingerprint(record.fingerprint)
                    if let date = record.lastSeen {
                        LabeledContent("Last seen", value: date.formatted())
                    }
                    ForEach(Array((record.provenance ?? []).enumerated()), id: \.offset) { _, provenance in
                        VStack(alignment: .leading) {
                            Text("Settings history").font(.subheadline.bold())
                            Text(verbatim: provenance.sourceName + " · " + provenance.date.formatted())
                            Text(provenance.kind == .transferredFrom ? "Transferred from another record" : "Migrated from earlier identifiers")
                            Text(verbatim: provenance.sourceObservationIDs.map(\.rawValue).joined(separator: ", "))
                            Text(provenance.categories.map(identityLabel).joined(separator: ", "))
                        }.font(.caption)
                    }
                }
                if let explanation = model.identityExplanation(for: entry) {
                    Text(decision(explanation)).font(.callout.bold())
                    fingerprint(explanation.observed)
                    ForEach(explanation.assessments, id: \.recordID) { assessment in
                        DisclosureGroup(model.rememberedName(forRecordID: assessment.recordID)) {
                            LabeledContent("App record", value: assessment.recordID.rawValue)
                            LabeledContent("Fingerprint score", value: assessment.confidence.score.formatted())
                            LabeledContent("Recognition threshold", value: explanation.recognitionThreshold.formatted())
                            Text(assessment.conflict.map { identityLabel($0.rawValue) } ?? String(localized: "No conflicting vendor, model or serial"))
                            if assessment.heldByAnotherDisplay { Text("Claimed by another connected display") }
                            if assessment.serialMatches { Text("Qualified serial matches") }
                            if assessment.indexedUnderThisUUID { Text("macOS UUID points to this record") }
                            ForEach(assessment.fields, id: \.field) { field in
                                LabeledContent(identityLabel(field.field.rawValue), value: identityLabel(field.agreement.rawValue))
                            }
                        }.font(.caption)
                    }
                } else {
                    Text("This record is offline. There is no current fingerprint to compare; selecting it sends nothing to a display.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                if entry.isConnected {
                    if let migration = model.settingsMigrationPlan(for: entry) {
                        Button("Preview migration from earlier identifiers…") { transfer = migration }
                    }
                    Menu("Transfer settings from offline record…") {
                        ForEach(model.settingsTransferSources(for: entry)) { source in
                            Button(model.rememberedName(of: source)) { preview(from: source, to: entry) }
                        }
                    }.disabled(model.settingsTransferSources(for: entry).isEmpty)
                } else {
                    Menu("Transfer settings to connected display…") {
                        ForEach(model.settingsTransferDestinations(for: entry)) { destination in
                            Button(model.rememberedName(of: destination)) { preview(from: entry, to: destination) }
                        }
                    }.disabled(model.settingsTransferDestinations(for: entry).isEmpty)
                }
                Text("Transfer replaces the selected destination settings and forgets the source record after confirmation. Physical identities stay separate. Migration moves selected preferences between identifiers of one recognized record. Cancel changes nothing.")
                    .font(.caption).foregroundStyle(.secondary)
                if let outcome { Text(outcome).font(.callout) }
            } else {
                Text("This display is no longer remembered.")
            }
        }
        .confirmationDialog("Change identification strategy?", isPresented: Binding(
            get: { strategyChoice != nil }, set: { if !$0 { strategyChoice = nil } })) {
            Button("Change strategy") {
                if let strategyChoice, let record = entry?.record {
                    Task { await model.setIdentityStrategy(strategyChoice, for: record) }
                }
                strategyChoice = nil
            }
            Button("Cancel", role: .cancel) { strategyChoice = nil }
        } message: {
            Text("This changes future recognition only. It can create a new record when evidence no longer meets the strategy. Preferences are not transferred automatically. Conflicts and ties remain fail-closed.")
        }
        .textSelection(.enabled)
        .sheet(isPresented: Binding(get: { transfer != nil }, set: { if !$0 { transfer = nil } })) {
            if let transfer {
                DisplaySettingsTransferSheet(plan: transfer) { result in
                    self.transfer = nil
                    outcome = result
                }.environmentObject(model)
            }
        }
    }

    private func preview(from source: RememberedDisplay, to destination: RememberedDisplay) {
        if case .success(let plan) = model.settingsTransferPlan(from: source, to: destination) { transfer = plan }
    }

    private func fingerprint(_ value: DisplayFingerprint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Vendor / product", value: "\(value.vendorID.map(String.init) ?? "—") / \(value.productID.map(String.init) ?? "—")")
            LabeledContent("Serial", value: value.serialNumber ?? value.serialHash ?? "—")
            LabeledContent("System name", value: value.modelName ?? "—")
            LabeledContent("EDID hash", value: value.edidHash ?? "—")
            LabeledContent("Manufacture year / week", value: "\(value.manufactureYear.map(String.init) ?? "—") / \(value.manufactureWeek.map(String.init) ?? "—")")
            LabeledContent("Physical size (mm)", value: "\(value.physicalWidthMM.map(String.init) ?? "—") × \(value.physicalHeightMM.map(String.init) ?? "—")")
        }.font(.caption).monospacedDigit()
    }

    private func decision(_ explanation: IdentityMatchExplanation) -> String {
        switch explanation.decision {
        case .record(_, let evidence):
            switch evidence {
            case .scored: return String(localized: "Recognized by a unique fingerprint score")
            case .cgUUID: return String(localized: "Recognized by macOS UUID")
            case .serial: return String(localized: "Recognized by qualified serial")
            case .serialAndCGUUID: return String(localized: "Recognized by qualified serial and macOS UUID")
            }
        case .newRecord: return String(localized: "No remembered identity matched; a new record was created")
        case .ambiguous(_, let reason): return identityLabel(reason.rawValue)
        }
    }
}

struct DisplayIdentityCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    var body: some View {
        if let entry = model.rememberedDisplays.first(where: { $0.observationIDs.contains(display.recordID) }) {
            ODCard(title: String(localized: "Identity and settings transfer")) {
                DisclosureGroup("Explain recognition and transfer settings") {
                    DisplayIdentityView(entryID: entry.id).padding(12)
                }.padding(12)
            }
        }
        #if !PUBLIC_API_ONLY
        if display.displayClass == .external {
            DDCChannelPairingView(display: display).id(display.recordID)
        }
        #endif
    }
}
#endif
