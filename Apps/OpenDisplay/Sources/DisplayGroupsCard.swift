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
        ODCard(title: "Группы экранов",
               footnote: "Изменение яркости одного экрана меняет яркость всей группы с учётом индивидуальных поправок. "
                       + "Если сразу после синхронизации изменить яркость ведомого экрана, программа запомнит новую поправку. "
                       + "Экраны в группах не участвуют в адаптивной регулировке.") {
            if model.settings.displayGroups.isEmpty {
                Text("Объедините экраны для совместной регулировки яркости.")
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

private struct DisplayGroupSection: View {
    @EnvironmentObject private var model: AppModel
    let group: DisplayGroup
    @State private var draftName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ODRow("Название группы", secondary: memberSummary) {
                HStack(spacing: ODSpacing.sm) {
                    TextField("Название группы", text: $draftName)
                        .textFieldStyle(.roundedBorder).frame(width: 140)
                        .onSubmit { commitName() }
                    Button(role: .destructive) {
                        model.deleteDisplayGroup(group)
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Удалить группу «\(group.name)»")
                }
            }
            ODDivider()
            ODRow("Синхронизация") {
                HStack(spacing: ODSpacing.md) {
                    Toggle("Яркость", isOn: Binding(
                        get: { group.syncBrightness },
                        set: { model.setDisplayGroupSyncBrightness($0, for: group) }))
                    Toggle("Контраст", isOn: Binding(
                        get: { group.syncContrast },
                        set: { model.setDisplayGroupSyncContrast($0, for: group) }))
                }
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
        return "Экранов: \(group.memberRecordIDs.count) \u{00B7} подключено: \(connected.count)"
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
                if isMember, group.syncBrightness {
                    Text(offsetLabel)
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    Slider(value: offsetBinding, in: offsetRange).frame(width: 110)
                        .accessibilityLabel("Поправка яркости экрана \(model.rememberedDisplayName(for: member))")
                        .help("Индивидуальная поправка яркости при общей регулировке группы")
                }
                Toggle("", isOn: Binding(
                    get: { isMember },
                    set: { model.setDisplayGroupMembership(member, in: group, isMember: $0) }))
                    .labelsHidden()
                    .accessibilityLabel("Включить экран \(model.rememberedDisplayName(for: member)) в группу «\(group.name)»")
            }
        }
    }

    private var isMember: Bool { group.contains(member) }

    /// Names the two states worth explaining: a display another group already owns (ticking this one
    /// moves it here, since a display belongs to one group), and a display that isn't plugged in —
    /// which the list now offers from the registry, so the row has to say so.
    private var membershipNote: String? {
        if !isMember, let other = model.displayGroup(containing: member) { return "В группе «\(other.name)»" }
        return isConnected ? nil : "Не подключён"
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
        ODRow("Новая группа") {
            HStack(spacing: ODSpacing.sm) {
                TextField("Название", text: $draftName)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
                    .onSubmit { create() }
                Button("Добавить") { create() }
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func create() {
        if model.createDisplayGroup(named: draftName) { draftName = "" }
    }
}
#endif
