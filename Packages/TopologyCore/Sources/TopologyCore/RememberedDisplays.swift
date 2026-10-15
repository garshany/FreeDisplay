import DisplayDomain
import Foundation

/// One display OpenDisplay remembers, as the Settings browser lists it (SD-09, FB-13): a registry
/// record and every observation id (`cg:<uuid>`) the per-display stores may key it by, or — for a
/// display the registry never named (provisional, or a turned-off entry with no record) — that one
/// observation id alone.
///
/// "Remembered" is about OpenDisplay's own records. Forgetting one never disconnects anything and
/// cannot remove a display macOS still detects: it would simply be rediscovered.
public struct RememberedDisplay: Hashable, Sendable, Identifiable {
    public enum Status: String, Hashable, Sendable, CaseIterable {
        /// macOS lists it right now (lit, mirrored or inactive).
        case connected
        /// OpenDisplay switched it off; its ledger entry is how OpenDisplay brings it back.
        case turnedOff
        /// OpenDisplay switched it off and the last reconnect the user asked for found no display.
        case reconnectFailed
        /// Not detected now and not switched off by OpenDisplay — only the saved settings remain.
        case notConnected
    }

    /// The registry record id, or the observation id for an entry without a persisted record.
    public var id: String
    /// The registry record (alias, model, last seen), when there is one — including a provisional
    /// record for a live display the registry couldn't tell apart from another.
    public var record: DisplayRecord?
    /// True when `record` is persisted in the registry (forgetting it removes it there).
    public var isRegistered: Bool
    /// Every id the per-display stores may use for this display, sorted.
    public var observationIDs: [DisplayRecordID]
    public var status: Status
    /// Every managed-offline ledger entry under this display's ids — usually one, but the same
    /// monitor can have been switched off under two of its UUIDs (two ports).
    public var offlineEntries: [ManagedOfflineDisplay]
    /// A connected display the registry couldn't tell apart from this record names it as a
    /// candidate: "not connected" may then be this very display under another id. Shown, not acted on.
    public var mayBeConnectedDisplay: Bool

    /// The ledger entry that speaks for the display: one still owed a reconnect before a failed one.
    public var offline: ManagedOfflineDisplay? {
        offlineEntries.first { $0.reconnectFailedAt == nil } ?? offlineEntries.first
    }

    public init(id: String, record: DisplayRecord?, isRegistered: Bool, observationIDs: [DisplayRecordID],
                status: Status, offlineEntries: [ManagedOfflineDisplay], mayBeConnectedDisplay: Bool = false) {
        self.id = id
        self.record = record
        self.isRegistered = isRegistered
        self.observationIDs = observationIDs
        self.status = status
        self.offlineEntries = offlineEntries
        self.mayBeConnectedDisplay = mayBeConnectedDisplay
    }

    public init(id: String, record: DisplayRecord?, isRegistered: Bool, observationIDs: [DisplayRecordID],
                status: Status, offline: ManagedOfflineDisplay?, mayBeConnectedDisplay: Bool = false) {
        self.init(id: id, record: record, isRegistered: isRegistered, observationIDs: observationIDs,
                  status: status, offlineEntries: offline.map { [$0] } ?? [],
                  mayBeConnectedDisplay: mayBeConnectedDisplay)
    }

    public var isConnected: Bool { status == .connected }
    /// The ledger entry is this display's recovery record: forgetting it is a real loss.
    public var isTurnedOffByApp: Bool { status == .turnedOff || status == .reconnectFailed }

    /// What Settings may offer: a detected display can only have its saved settings reset (it is
    /// rediscovered at once anyway); anything else can be forgotten — unless `forgetRefusal` says no.
    public var cleanupMode: RememberedDisplayCleanup.Mode { isConnected ? .reset : .forget }

    /// Why this entry can't be forgotten right now, if it can't.
    ///
    /// A display OpenDisplay switched off is still owed its way back: the ledger entry is the only
    /// handle to it, and the always-one-active safety net relights only what the ledger names. So it
    /// can be forgotten only once a reconnect has been tried and found no display — the case of a
    /// monitor unplugged while off, whose card would otherwise never go away. The built-in panel is
    /// never in that case: it can't have been unplugged, and forgetting its entry would leave the
    /// safety net nothing to light when the last external goes. Forgetting drops every ledger entry
    /// under the display's ids, so each of them has to allow it (`status` already says
    /// `.turnedOff` while any one is still owed).
    public var forgetRefusal: RememberedDisplayCleanup.Refusal? {
        switch status {
        case .connected: return .connected
        case .turnedOff: return .turnedOffByApp
        case .reconnectFailed:
            return offlineEntries.contains { $0.displayClass == .builtIn } ? .builtInTurnedOff : nil
        case .notConnected: return nil
        }
    }
}

public enum RememberedDisplayInventory {
    /// One live display as the app knows it: its observation id and the record it resolved to.
    public struct Live: Hashable, Sendable {
        public var observationID: DisplayRecordID
        public var record: DisplayRecord?
        public init(observationID: DisplayRecordID, record: DisplayRecord?) {
            self.observationID = observationID
            self.record = record
        }
    }

    /// Merges the registry, the live displays and the managed-offline ledger into one entry per
    /// display. Order: connected, then switched off by OpenDisplay, then not connected; by name
    /// (alias → model → ledger name) within each, then by id so equal names never swap.
    public static func build(
        registry: [(record: DisplayRecord, observationIDs: [DisplayRecordID])],
        live: [Live],
        offline: [ManagedOfflineDisplay]
    ) -> [RememberedDisplay] {
        var entries: [RememberedDisplay] = []
        var claimed: Set<DisplayRecordID> = []
        let registeredIDs = Set(registry.map(\.record.id))
        let liveCandidates = Set(live.compactMap(\.record?.unresolvedCandidates).joined())

        for (record, indexed) in registry {
            var ids = Set(indexed)
            // A UUID-less display (`cgid:<n>`) has no index entry; the live resolution is the only link.
            for display in live where display.record?.id == record.id { ids.insert(display.observationID) }
            let offlineEntries = offline.filter { ids.contains($0.recordID) }
            claimed.formUnion(ids)
            let isLive = live.contains { ids.contains($0.observationID) || $0.record?.id == record.id }
            entries.append(RememberedDisplay(
                id: record.id.rawValue, record: record, isRegistered: true,
                observationIDs: ids.sorted { $0.rawValue < $1.rawValue },
                status: status(live: isLive, offline: offlineEntries), offlineEntries: offlineEntries,
                mayBeConnectedDisplay: !isLive && liveCandidates.contains(record.id)))
        }
        for display in live where !claimed.contains(display.observationID) {
            // Provisional (ambiguous) or not yet resolved: the observation id is all there is.
            claimed.insert(display.observationID)
            entries.append(RememberedDisplay(
                id: display.observationID.rawValue, record: display.record,
                isRegistered: display.record.map { registeredIDs.contains($0.id) } ?? false,
                observationIDs: [display.observationID], status: .connected,
                offlineEntries: offline.filter { $0.recordID == display.observationID }))
        }
        for entry in offline where !claimed.contains(entry.recordID) {
            claimed.insert(entry.recordID)
            entries.append(RememberedDisplay(
                id: entry.recordID.rawValue, record: nil, isRegistered: false,
                observationIDs: [entry.recordID], status: status(live: false, offline: [entry]),
                offlineEntries: [entry]))
        }
        return entries.sorted { lhs, rhs in
            let l = rank(lhs.status), r = rank(rhs.status)
            if l != r { return l < r }
            let byName = name(of: lhs).compare(name(of: rhs), options: [.caseInsensitive, .numeric])
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    /// The name the inventory sorts by. The app shows a localized form of the same fallbacks.
    public static func name(of entry: RememberedDisplay) -> String {
        if let alias = entry.record?.alias, !alias.isEmpty { return alias }
        if let model = entry.record?.fingerprint.modelName, !model.isEmpty { return model }
        if let name = entry.offline?.name, !name.isEmpty { return name }
        return entry.record?.friendlyName() ?? entry.id
    }

    /// Switched off while any ledger entry is still owed a reconnect; "didn't reconnect" only once
    /// every one of them has had a reconnect find no display.
    private static func status(live: Bool, offline: [ManagedOfflineDisplay]) -> RememberedDisplay.Status {
        if live { return .connected }
        if offline.isEmpty { return .notConnected }
        return offline.contains { $0.reconnectFailedAt == nil } ? .turnedOff : .reconnectFailed
    }

    private static func rank(_ status: RememberedDisplay.Status) -> Int {
        switch status {
        case .connected: return 0
        case .reconnectFailed: return 1
        case .turnedOff: return 2
        case .notConnected: return 3
        }
    }
}

/// What forgetting a remembered display — or resetting a connected one's saved settings — removes
/// and what it keeps, decided before anything is touched so the confirmation can list it exactly
/// (FB-13: "confirmed deletion lists affected settings/associations").
///
/// Both modes remove OpenDisplay's own per-display data: the name and tags, favourite modes, tray
/// presentation and order, group memberships, protected layouts whose display set includes it, the
/// software-brightness and Apple-DDC choices, a hand-paired DDC channel and Adaptive Display's
/// learned offset.
///
/// - `forget` (not detected): the registry record goes too, and so does the managed-offline ledger
///   entry of a display OpenDisplay switched off — that entry is its recovery record, which the
///   confirmation must say. Only allowed once a reconnect found no display, and never for the
///   built-in panel (`RememberedDisplay.forgetRefusal`).
/// - `reset` (detected): the record stays, so the display is still recognized; the ledger is never
///   touched — a detected display can still be owed an "off" after a wake.
///
/// Neither mode touches the pending restores (FaceLight, app presets, the evening colour preset):
/// they hand the monitor its own values back when it next appears, and dropping them would leave it
/// at the applied values. Rules the user wrote that target the display (input-switch hotkeys, app
/// presets) are kept and listed. Nothing here writes to a monitor or to macOS's display
/// configuration; a monitor factory reset is a different, separately named operation.
public enum RememberedDisplayCleanup {
    public enum Mode: String, Hashable, Sendable {
        case forget, reset
    }

    public enum Refusal: Error, Hashable, Sendable {
        /// Forgetting a display macOS detects would only rediscover it — and claiming otherwise
        /// would promise a disconnect that never happens. Reset its settings instead.
        case connected
        /// OpenDisplay switched it off and nothing says it is gone: reconnect it first. If that
        /// finds no display, it can be forgotten.
        case turnedOffByApp
        /// The built-in panel OpenDisplay switched off: its entry is what the safety net relights.
        case builtInTurnedOff
    }

    /// A restore OpenDisplay still owes this display, kept by both modes.
    public enum PendingRestore: String, Hashable, Sendable, CaseIterable {
        case faceLight, appPreset, eveningColorPreset
    }

    public struct Plan: Hashable, Sendable {
        public var mode: Mode
        public var observationIDs: Set<DisplayRecordID>
        /// The registry record removed (`forget`) or cleared of name and tags (`reset`).
        public var registryRecordID: DisplayRecordID?
        public var alias: String?
        public var tagCount: Int
        public var favoriteModeCount: Int
        public var groupNames: [String]
        public var protectedLayoutKeys: [String]
        public var hasMenuPreferences: Bool
        public var softwareBrightness: Bool
        public var appleDDCOverride: Bool
        /// A DDC channel the user paired with this display by hand (`DDCChannelMappingPolicy`).
        public var ddcChannelMapping: Bool
        public var adaptiveOffset: Bool
        /// `forget` of a display OpenDisplay switched off: its recovery record goes with it.
        public var removesTurnedOffRecord: Bool
        public var keptRestores: [PendingRestore]
        /// Rules the user wrote that name this display — input-switch hotkeys and app presets aimed
        /// at it. Kept: they are the user's own instructions, edited where they were made, and they
        /// work again if the display comes back under the same id. Listed so nothing is kept silently.
        public var keptInputSwitchHotkeys: Int
        public var keptAppPresetNames: [String]

        /// Nothing but the record itself would change.
        public var removesOnlyRecord: Bool {
            alias == nil && tagCount == 0 && favoriteModeCount == 0 && groupNames.isEmpty
                && protectedLayoutKeys.isEmpty && !hasMenuPreferences && !softwareBrightness
                && !appleDDCOverride && !ddcChannelMapping && !adaptiveOffset && !removesTurnedOffRecord
        }
    }

    /// The plan for `display` in `mode`. Forgetting throws `display.forgetRefusal` when there is one
    /// (a detected display, or one OpenDisplay switched off that is still owed its way back);
    /// resetting is only for a detected display.
    public static func plan(
        for display: RememberedDisplay,
        mode: Mode,
        settings: OpenDisplaySettings,
        favorites: FavoriteResolutions,
        menuLayout: MenuLayoutSettings,
        ledger: [ManagedOfflineDisplay]
    ) throws(Refusal) -> Plan {
        if mode == .forget, let refusal = display.forgetRefusal { throw refusal }
        let ids = Set(display.observationIDs)
        let raw = Set(ids.map(\.rawValue))
        let record = display.isRegistered ? display.record : nil
        let groups = settings.displayGroups.filter { group in group.memberRecordIDs.contains(where: ids.contains) }
        let layouts = settings.protectedLayouts.filter { _, config in
            LayoutProtectionPolicy.members(of: config).contains(where: ids.contains)
        }
        var kept: [PendingRestore] = []
        if !raw.isDisjoint(with: settings.faceLightPriorStateByDisplay.keys) { kept.append(.faceLight) }
        if !raw.isDisjoint(with: settings.appPresetPriorStateByDisplay.keys) { kept.append(.appPreset) }
        if !raw.isDisjoint(with: settings.adaptiveDayPresetByDisplay.keys) { kept.append(.eveningColorPreset) }
        return Plan(
            mode: mode,
            observationIDs: ids,
            registryRecordID: record?.id,
            alias: record?.alias.flatMap { $0.isEmpty ? nil : $0 },
            tagCount: record?.tags.count ?? 0,
            favoriteModeCount: ids.reduce(0) { $0 + favorites.favoriteKeys(for: $1).count },
            groupNames: groups.map(\.name).sorted(),
            protectedLayoutKeys: layouts.keys.sorted(),
            hasMenuPreferences: menuLayout.remembers(ids),
            softwareBrightness: !raw.isDisjoint(with: settings.softwareBrightnessDisplayIDs),
            appleDDCOverride: !raw.isDisjoint(with: settings.ddcAppleDisplayOverrideIDs),
            ddcChannelMapping: settings.ddcChannelMappings.contains { ids.contains($0.displayID) },
            adaptiveOffset: !raw.isDisjoint(with: settings.adaptiveBrightnessOffsetByDisplay.keys),
            removesTurnedOffRecord: mode == .forget && ledger.contains { ids.contains($0.recordID) },
            keptRestores: kept,
            keptInputSwitchHotkeys: settings.hotkeyShortcuts.inputSwitchBindings.filter { ids.contains($0.displayID) }.count,
            keptAppPresetNames: settings.appPresets.compactMap { preset in
                guard case .display(let target) = preset.target, raw.contains(target) else { return nil }
                return preset.applicationName
            }.sorted())
    }

    /// The settings without this display's preferences and associations. Restore ledgers stay.
    public static func applying(_ plan: Plan, to settings: OpenDisplaySettings) -> OpenDisplaySettings {
        var updated = settings
        let raw = Set(plan.observationIDs.map(\.rawValue))
        for group in updated.displayGroups where group.memberRecordIDs.contains(where: plan.observationIDs.contains) {
            for member in group.memberRecordIDs where plan.observationIDs.contains(member) {
                updated.displayGroups = DisplayGroupStore.removeMember(member, from: group.id, in: updated.displayGroups)
            }
        }
        for key in plan.protectedLayoutKeys { updated.protectedLayouts[key] = nil }
        updated.softwareBrightnessDisplayIDs.subtract(raw)
        updated.ddcAppleDisplayOverrideIDs.subtract(raw)
        updated.ddcChannelMappings.removeAll { plan.observationIDs.contains($0.displayID) }
        for key in raw { updated.adaptiveBrightnessOffsetByDisplay[key] = nil }
        return updated
    }

    public static func applying(_ plan: Plan, to favorites: FavoriteResolutions) -> FavoriteResolutions {
        var updated = favorites
        for id in plan.observationIDs { updated.removeAll(for: id) }
        return updated
    }

    public static func applying(_ plan: Plan, to layout: MenuLayoutSettings) -> MenuLayoutSettings {
        layout.forgetting(plan.observationIDs)
    }

    /// The ledger after the plan: only `forget` drops this display's entry.
    public static func applying(_ plan: Plan, to ledger: [ManagedOfflineDisplay]) -> [ManagedOfflineDisplay] {
        guard plan.mode == .forget else { return ledger }
        return ledger.filter { !plan.observationIDs.contains($0.recordID) }
    }
}
