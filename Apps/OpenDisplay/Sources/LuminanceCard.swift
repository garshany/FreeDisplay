// SPDX-License-Identifier: GPL-3.0-or-later
// Original FreeDisplay implementation: luminance anchors and estimated nits (SD-13, TR-13, TB-13).
// Labels only — nothing here reaches the display.
#if os(macOS)
import AppKit
import CoreGraphicsProvider
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI

/// Settings → Displays → Luminance: the anchors the user entered (with the basis they state), the
/// values the display's EDID reports, and the nits estimated for the current brightness — each
/// labelled with where it came from. Entering a value commits on Return or when the field loses
/// focus; Escape puts the field back; an empty field clears the entry.
struct LuminanceCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @State private var reported = ReportedLuminance()
    @State private var notice: String?

    private var settings: LuminanceAnchorSettings { model.luminanceAnchors(for: display) ?? LuminanceAnchorSettings() }

    private var screen: NSScreen? { display.cgDisplayID.flatMap(DisplayScreenLookup.screen(for:)) }

    private var estimateInput: (position: Double?, note: String?) {
        let route: DisplayReportFacts.BrightnessRoute
        switch model.brightnessMethod[display.recordID] {
        case .native: route = .system
        case .hardware: route = .ddc
        case .software: route = .softwareGamma
        case nil: route = .notResolved
        }
        return DisplayInformationReport.luminanceEstimateInput(
            route, level: model.brightness[display.recordID].map(Double.init), .app)
    }

    var body: some View {
        let settings = self.settings
        let entries = LuminanceAnchorResolver.resolveAll(settings, reported: reported)
        let showsHDR = LuminanceAnchorResolver.showsHDRAnchors(
            reported: reported,
            potentialEDRHeadroom: screen.map { Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue) },
            settings: settings)
        let input = estimateInput
        let section = LuminanceReport.section(settings: settings, reported: reported, includeHDR: showsHDR,
                                              brightnessPosition: input.position, estimateNote: input.note, .app)
        ODCard(title: String(localized: "Luminance")) {
            ODRow(String(localized: "Use the values you entered"),
                  secondary: String(localized: "Off keeps them but labels with reported values only")) {
                Toggle("", isOn: Binding(
                    get: { settings.manualValuesEnabled },
                    set: { enabled in
                        var updated = settings
                        updated.manualValuesEnabled = enabled
                        model.setLuminanceAnchors(updated, for: display)
                    }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            ForEach(LuminanceAnchor.allCases.filter { showsHDR || !$0.isHDR }, id: \.self) { anchor in
                ODDivider()
                LuminanceAnchorRow(anchor: anchor, entry: entries[anchor], stored: settings.overrides[anchor],
                                   basis: Binding(
                                       get: { self.settings.overrides[anchor]?.basis ?? .unspecified },
                                       set: { model.setLuminanceAnchors(self.settings.settingBasis($0, for: anchor), for: display) }),
                                   commit: { commit(anchor, $0) })
            }
            ODDivider()
            let l = ReportLocalizer.app
            ODRow(input.position.map { l.fill("At the current brightness (%1%)", l.decimal($0 * 100, 0)) }
                  ?? l("At the current brightness")) {
                Text(input.position.map {
                    LuminanceReport.estimateText(LuminanceAnchorResolver.estimateNits(atPosition: $0, anchors: entries), l)
                } ?? input.note ?? "")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(section.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
        .task(id: display.cgDisplayID) { await readReported() }
    }

    /// The anchors the EDID states. Only reads (the public IORegistry walk the report and the EDID
    /// pane use); a display whose EDID can't be tied to it alone reports nothing.
    private func readReported() async {
        notice = nil
        reported = ReportedLuminance()
        guard let cgID = display.cgDisplayID else { reported = ReportedLuminance(); return }
        let lookup = await Task.detached(priority: .userInitiated) { EDIDReader.lookup(for: cgID) }.value
        guard !Task.isCancelled else { return }
        if case .matched(let bytes) = lookup {
            let decoded = EDIDDecoder.decode(bytes)
            reported = ReportedLuminance.from(decoded)
            if !decoded.isStructurallyValid {
                notice = String(localized: "Reported luminance is unavailable because the EDID has structural errors.")
            }
        } else {
            reported = ReportedLuminance()
        }
    }

    /// Stores a committed field. Nil is an emptied field: the entry is cleared.
    private func commit(_ anchor: LuminanceAnchor, _ value: Double?) {
        let current = settings
        guard let value else {
            notice = nil
            model.setLuminanceAnchors(current.clearing(anchor), for: display)
            return
        }
        do {
            let edit = try current.setting(anchor, nits: value)
            model.setLuminanceAnchors(edit.settings, for: display)
            var lines: [String] = []
            if edit.raisedToZero { lines.append(String(localized: "Light can’t be negative, so 0 nits was stored.")) }
            for (partner, nits) in edit.movedPartners.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                lines.append(String(localized: "\(LuminanceReport.anchorName(partner, .app)) moved to \(LuminanceReport.nitsText(nits, .app)) to keep the pair in order."))
            }
            notice = lines.isEmpty ? nil : lines.joined(separator: "\n")
        } catch {
            notice = String(localized: "That isn’t a usable number. Nothing was changed.")
        }
    }
}

/// One anchor: its name, the value in use with its provenance, a field for the entered value, the
/// stated basis and a clear button.
private struct LuminanceAnchorRow: View {
    let anchor: LuminanceAnchor
    let entry: LuminanceAnchorResolver.Entry?
    let stored: ManualLuminance?
    @Binding var basis: ManualLuminanceBasis
    let commit: (Double?) -> Void
    @State private var draft = ""
    @State private var rejected = false
    @FocusState private var focused: Bool

    private var storedText: String {
        // An untouched field must not round and overwrite a more precise saved anchor on blur.
        stored.map { String($0.nits).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".") } ?? ""
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(LuminanceReport.anchorName(anchor, .app)).font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.map { LuminanceReport.entryText($0, .app) } ?? String(localized: "Unknown"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if rejected {
                    Text("Not a number. The field was put back.").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 6)
            TextField(String(localized: "automatic"), text: $draft)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .frame(width: 80).focused($focused)
                .onSubmit(submit)
                .onExitCommand { draft = storedText; rejected = false; focused = false }
            Text("nits").font(.system(size: 11)).foregroundStyle(.secondary)
            Menu {
                Picker("Basis", selection: $basis) {
                    Text("Not specified").tag(ManualLuminanceBasis.unspecified)
                    Text("From the specification").tag(ManualLuminanceBasis.specification)
                    Text("Measured by me").tag(ManualLuminanceBasis.userMeasurement)
                    Text("My estimate").tag(ManualLuminanceBasis.userEstimate)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "info.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(stored == nil)
            .help(String(localized: "Where the value you entered comes from"))
            Button { commit(nil) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .disabled(stored == nil)
                .help(String(localized: "Clear the entered value and go back to the reported one, if any"))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .onAppear { draft = storedText }
        // Whatever changed the stored value — this field's commit, a partner moved to keep a pair in
        // order, a clear — the field shows what is stored now.
        .onChange(of: stored) { _, _ in draft = storedText }
        .onChange(of: focused) { _, isFocused in if !isFocused { submit() } }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != storedText else { rejected = false; return }
        if text.isEmpty {
            rejected = false
            commit(nil)
            return
        }
        guard let value = try? LuminanceAnchorInput.parse(text, locale: .current) else {
            rejected = true
            draft = storedText
            return
        }
        rejected = false
        commit(value)
    }
}
#endif
