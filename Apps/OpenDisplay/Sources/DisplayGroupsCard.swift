#if os(macOS)
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// Settings → Displays → "Groups" (Issue #39). Display-agnostic, so it renders once at the bottom of
/// the Displays tab rather than per display: create/rename/delete a group, tick which displays belong
/// to it, and nudge each member's offset. The per-display "Synced with <group>" caption lives in
/// `DisplayDetailView`.
struct DisplayGroupsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ODCard(title: String(localized: "Display groups"),
               footnote: String(localized: "Moving any member’s brightness moves the rest, the way the group’s mode says. Hold Shift while dragging a brightness slider to change only that display. Levels are each display’s own percentage, not measured brightness. Grouped displays, including the default group’s, are left out of Adaptive Display.")) {
            DefaultDisplayGroupSection()
            ODDivider()
            if model.settings.displayGroups.isEmpty {
                Text("Group displays to move their brightness together.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 10)
            } else {
                ForEach(model.settings.displayGroups) { group in
                    DisplayGroupSection(group: group)
                    ODDivider()
                }
            }
            NewDisplayGroupRow()
        }
    }
}

/// The Default group (SO-05/AM-17/TB-14): basic brightness sync for every connected display no named
/// group holds. Off until switched on; its members are shown live rather than ticked, because they
/// are whatever is connected — and a display moved into a named group leaves it.
private struct DefaultDisplayGroupSection: View {
    @EnvironmentObject private var model: AppModel

    private var group: DisplayGroup { model.settings.defaultDisplayGroup }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ODRow(String(localized: "Sync brightness of all other displays"), secondary: memberSummary) {
                Toggle("", isOn: Binding(get: { group.syncBrightness },
                                         set: { model.setDefaultGroupSyncBrightness($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Default group brightness sync")
            }
            if group.syncBrightness {
                ODDivider()
                // Offsets need per-member rows to be seen and edited; the default group offers the
                // two plain modes.
                BrightnessSyncModeRows(group: group, modes: [.delta, .absolute])
            }
        }
    }

    /// Who the default group covers right now, by name — it changes with what is plugged in.
    private var memberSummary: String {
        let members = model.defaultGroupMembers
        guard !members.isEmpty else { return String(localized: "Every connected display is in a named group") }
        let names = members.map { model.rememberedDisplayName(for: $0) }.joined(separator: ", ")
        return String(localized: "Default group: \(names)")
    }
}

/// The brightness-sync mode picker and the outside-changes switch, shared by the default and the
/// named groups. Each mode explains itself under the picker, so the choice is never a bare word.
private struct BrightnessSyncModeRows: View {
    @EnvironmentObject private var model: AppModel
    let group: DisplayGroup
    let modes: [BrightnessSyncMode]

    var body: some View {
        ODRow(String(localized: "Brightness mode"), secondary: explanation(group.brightnessMode)) {
            Picker("", selection: Binding(get: { group.brightnessMode },
                                          set: { model.setDisplayGroupBrightnessMode($0, for: group) })) {
                ForEach(modes, id: \.self) { mode in Text(title(mode)).tag(mode) }
            }
            .labelsHidden().fixedSize()
        }
        // Changes made outside the app can only be observed through native brightness reads, which
        // the public-API-only build doesn't have — there is nothing for the switch to decide there.
        #if !PUBLIC_API_ONLY
        ODDivider()
        ODRow(String(localized: "Follow changes made outside OpenDisplay"),
              secondary: String(localized: "macOS brightness keys, System Settings, automatic brightness")) {
            Toggle("", isOn: Binding(get: { group.followsOutsideChanges },
                                     set: { model.setDisplayGroupFollowsOutsideChanges($0, for: group) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("Follow changes made outside OpenDisplay")
        }
        #endif
    }

    private func title(_ mode: BrightnessSyncMode) -> String {
        switch mode {
        case .offsets: return String(localized: "Learned offsets")
        case .absolute: return String(localized: "Absolute")
        case .delta: return String(localized: "Delta")
        }
    }

    private func explanation(_ mode: BrightnessSyncMode) -> String {
        switch mode {
        case .offsets:
            return String(localized: "Each display follows at its own offset; nudging one right after it follows re-teaches it.")
        case .absolute:
            return String(localized: "Every display takes the leading display’s brightness percentage.")
        case .delta:
            return String(localized: "Every display moves by the same amount, keeping existing differences until one reaches its limit.")
        }
    }
}

private struct DisplayGroupSection: View {
    @EnvironmentObject private var model: AppModel
    let group: DisplayGroup
    @State private var draftName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ODRow(String(localized: "Group name"), secondary: memberSummary) {
                HStack(spacing: ODSpacing.sm) {
                    TextField("Group name", text: $draftName)
                        .textFieldStyle(.roundedBorder).frame(width: 140)
                        .onSubmit { commitName() }
                    Button(role: .destructive) {
                        model.deleteDisplayGroup(group)
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete group “\(group.name)”")
                }
            }
            ODDivider()
            ODRow(String(localized: "Sync")) {
                HStack(spacing: ODSpacing.md) {
                    Toggle("Brightness", isOn: Binding(
                        get: { group.syncBrightness },
                        set: { model.setDisplayGroupSyncBrightness($0, for: group) }))
                    Toggle("Contrast", isOn: Binding(
                        get: { group.syncContrast },
                        set: { model.setDisplayGroupSyncContrast($0, for: group) }))
                }
            }
            if group.syncBrightness {
                ODDivider()
                BrightnessSyncModeRows(group: group, modes: BrightnessSyncMode.allCases)
            }
            ForEach(candidateMembers, id: \.self) { member in
                ODDivider()
                DisplayGroupMemberRow(group: group, member: member)
            }
        }
        .onAppear { draftName = group.name }
    }

    /// "3 displays · 2 connected", so a group whose members are partly unplugged reads honestly.
    private var memberSummary: String {
        let connected = group.memberRecordIDs.filter { member in
            model.displays.contains { $0.recordID == member }
        }
        return String(localized: "Displays: \(group.memberRecordIDs.count) · connected: \(connected.count)")
    }

    /// Every display that could sit in this group: the ones connected right now plus every display
    /// the registry remembers (so an unplugged monitor can still be ticked into the group), and
    /// finally this group's own members even if the registry has forgotten them — a member must
    /// always stay visible and removable.
    private var candidateMembers: [DisplayRecordID] {
        let offerable = model.groupMemberCandidates
        return offerable + group.memberRecordIDs.filter { !offerable.contains($0) }
    }

    /// Renaming can be refused (blank, or a name another group already holds) — put the field back to
    /// the stored name rather than leaving the user looking at a name that didn't take.
    private func commitName() {
        if !model.renameDisplayGroup(group, to: draftName) { draftName = group.name }
    }
}

private struct DisplayGroupMemberRow: View {
    @EnvironmentObject private var model: AppModel
    let group: DisplayGroup
    let member: DisplayRecordID

    var body: some View {
        ODRow(model.rememberedDisplayName(for: member), secondary: membershipNote) {
            HStack(spacing: ODSpacing.sm) {
                // Offsets only mean something in the offsets mode; the other modes keep them stored.
                if isMember, group.syncBrightness, group.brightnessMode == .offsets {
                    Text(offsetLabel)
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Slider(value: offsetBinding, in: offsetRange).frame(width: 110)
                        .accessibilityLabel("Brightness offset for \(model.rememberedDisplayName(for: member))")
                        .help("This display’s own brightness offset when the group moves together")
                }
                Toggle("", isOn: Binding(
                    get: { isMember },
                    set: { model.setDisplayGroupMembership(member, in: group, isMember: $0) }))
                    .labelsHidden()
                    .accessibilityLabel("Include \(model.rememberedDisplayName(for: member)) in group “\(group.name)”")
            }
        }
    }

    private var isMember: Bool { group.contains(member) }

    /// Names the two states worth explaining: a display another group already owns (ticking this one
    /// moves it here, since a display belongs to one group), and a display that isn't plugged in —
    /// which the list now offers from the registry, so the row has to say so.
    private var membershipNote: String? {
        if !isMember, let other = model.displayGroup(containing: member) { return String(localized: "In group “\(other.name)”") }
        return isConnected ? nil : String(localized: "Not connected")
    }

    private var isConnected: Bool {
        model.displays.contains { $0.recordID == member }
    }

    private var offsetLabel: String {
        let percent = Int((group.offset(for: member) * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    /// The nominal ±50% span, widened when a learned offset already sits outside it — otherwise the
    /// slider would snap a real learned value back the moment the row appeared.
    private var offsetRange: ClosedRange<Double> {
        let learned = abs(Double(group.offset(for: member)))
        let bound = max(Double(DisplayGroup.nominalOffsetLimit), learned)
        return -bound...bound
    }

    private var offsetBinding: Binding<Double> {
        Binding(get: { Double(group.offset(for: member)) },
                set: { model.setDisplayGroupOffset(Float($0), for: member, in: group) })
    }
}

private struct NewDisplayGroupRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var draftName = ""

    var body: some View {
        ODRow(String(localized: "New group")) {
            HStack(spacing: ODSpacing.sm) {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
                    .onSubmit { create() }
                Button("Add") { create() }
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func create() {
        if model.createDisplayGroup(named: draftName) { draftName = "" }
    }
}
#endif
