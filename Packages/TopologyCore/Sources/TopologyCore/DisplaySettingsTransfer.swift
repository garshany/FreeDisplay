import DisplayDomain
import Foundation

/// Moving a display's saved settings between identities, previewed before anything changes
/// (SD-10, FA-11, TB-09). OpenDisplay files most per-display preferences under the observation id
/// (`cg:<uuid>`), so two situations leave settings stranded:
///
/// - **Transfer** — the settings belong to another remembered record: a monitor replaced by a new
///   one, or a display the registry didn't recognize (its identity changed). The user picks the old
///   record as the source for a connected display. The destination's own values in each selected
///   category are *replaced*, not merged; the source record is then removed exactly as a confirmed
///   Forget would remove it. Identities never merge: the destination keeps its own fingerprint, so
///   two physical displays never become one record, and if the old display is ever seen again it is
///   recognized afresh. A positively different display (vendor, model or serial differ) is allowed —
///   that is the replaced-monitor case — but the plan says so and the user must acknowledge it.
/// - **Migration** — the registry recognized the display, but under a new identifier (another port,
///   a macOS UUID change), so settings saved under its earlier identifier no longer apply. They move
///   to the identifier it is connected under now, filling in only what that one lacks: whatever the
///   display already has of its own stays, and the conflicting earlier value stays where it was.
///
/// Some saved data is never moved, by design, and the plan lists it (`Retained`): the Apple-display
/// DDC override is a safety consent for one physical display; a hand-paired DDC channel was
/// confirmed by watching one monitor respond on one port; pending restores hold one monitor's own
/// values; input-switch hotkeys and app presets are rules the user wrote naming a display (input
/// codes are monitor-specific); protected layouts describe a whole desk. Nothing here writes to a
/// monitor or to macOS's display configuration. Cancelling — not applying the plan — changes nothing.
public enum DisplaySettingsTransfer {
    public enum Kind: String, Hashable, Sendable {
        case transfer, migrate
    }

    /// What can move, each independently selectable.
    public enum Category: String, Hashable, Sendable, CaseIterable {
        /// The name OpenDisplay shows (registry alias). Transfer only.
        case name
        /// Registry tags (`tag:` selectors). Transfer only.
        case tags
        case favoriteModes
        /// Hidden in the menu, custom icon and manual menu position. Transfer only: the menu already
        /// reads these under every identifier of one record.
        case menuPresentation
        /// Membership in a named display group, with the offset learned there.
        case groupMembership
        /// Software brightness instead of DDC.
        case softwareBrightness
        /// Adaptive Display's learned brightness offset.
        case adaptiveOffset
    }

    /// Saved data that never moves, listed so nothing stays behind silently.
    public enum Retained: String, Hashable, Sendable, CaseIterable {
        case appleDDCOverride, ddcChannelMapping, pendingRestores, inputSwitchHotkeys, appPresets, protectedLayouts
    }

    public struct GroupMembership: Hashable, Sendable {
        public var groupID: UUID
        public var groupName: String
        /// The id the display is a member under.
        public var memberID: DisplayRecordID
        public var offset: Float?
    }

    /// Everything saved for one display under a set of ids.
    public struct SavedSettings: Hashable, Sendable {
        public var alias: String?
        public var tags: Set<String>
        /// Newest first, across all the ids.
        public var favoriteKeys: [String]
        public var menuHidden: Bool
        public var menuIcon: String?
        /// Position in the manual menu order, when the display has one.
        public var menuOrderPosition: Int?
        public var group: GroupMembership?
        public var softwareBrightness: Bool
        public var adaptiveOffset: Float?
        public var appleDDCOverride: Bool
        public var ddcChannelMapping: Bool
        public var pendingRestores: [RememberedDisplayCleanup.PendingRestore]
        public var inputSwitchHotkeys: Int
        public var appPresetNames: [String]
        public var protectedLayoutKeys: [String]

        /// Whether a category holds anything but its default.
        public func has(_ category: Category) -> Bool {
            switch category {
            case .name: return alias != nil
            case .tags: return !tags.isEmpty
            case .favoriteModes: return !favoriteKeys.isEmpty
            case .menuPresentation: return menuHidden || menuIcon != nil || menuOrderPosition != nil
            case .groupMembership: return group != nil
            case .softwareBrightness: return softwareBrightness
            case .adaptiveOffset: return adaptiveOffset != nil
            }
        }

        public func holds(_ retained: Retained) -> Bool {
            switch retained {
            case .appleDDCOverride: return appleDDCOverride
            case .ddcChannelMapping: return ddcChannelMapping
            case .pendingRestores: return !pendingRestores.isEmpty
            case .inputSwitchHotkeys: return inputSwitchHotkeys > 0
            case .appPresets: return !appPresetNames.isEmpty
            case .protectedLayouts: return !protectedLayoutKeys.isEmpty
            }
        }

        /// The comparable value of a category (group membership compares group and offset, not the
        /// id the display is a member under).
        fileprivate func value(of category: Category) -> AnyHashable {
            switch category {
            case .name: return AnyHashable(alias)
            case .tags: return AnyHashable(tags)
            case .favoriteModes: return AnyHashable(favoriteKeys)
            case .menuPresentation:
                return AnyHashable([AnyHashable(menuHidden), AnyHashable(menuIcon), AnyHashable(menuOrderPosition)])
            case .groupMembership: return AnyHashable([AnyHashable(group?.groupID), AnyHashable(group?.offset)])
            case .softwareBrightness: return AnyHashable(softwareBrightness)
            case .adaptiveOffset: return AnyHashable(adaptiveOffset)
            }
        }
    }

    public enum Effect: String, Hashable, Sendable {
        /// Transfer: the destination's value gives way to the source's — which may be "none".
        case replace
        /// Migration: the display has no value of its own; the earlier identifier's moves over.
        case move
        /// Migration (favourite modes): the earlier identifier's entries join the display's own.
        case merge
        /// Migration: the display already has its own value; nothing moves, the earlier one stays.
        case conflict
    }

    public struct Change: Hashable, Sendable {
        public var category: Category
        public var effect: Effect
    }

    public enum Refusal: Error, Hashable, Sendable {
        /// Source and destination are the same display.
        case sameDisplay
        /// The source is connected: its settings are in use. Transfers come from an absent record.
        case sourceConnected
        /// The source can't be removed now (`RememberedDisplay.forgetRefusal`): OpenDisplay switched
        /// it off and still owes it a way back.
        case sourceOwedReconnect(RememberedDisplayCleanup.Refusal)
        /// A connected look-alike the registry couldn't tell apart may be this very record; only that
        /// display may take its settings (which is how the ambiguity is resolved).
        case sourceMayBeConnected
        /// Settings move onto a connected display only.
        case destinationNotConnected
        /// Migration: no earlier identifier holds anything this display lacks.
        case nothingToMove
    }

    public struct Plan: Hashable, Sendable {
        public var kind: Kind
        /// `RememberedDisplay.id` of each side, to find them again before applying.
        public var sourceEntryID: String
        public var destinationEntryID: String
        public var sourceIDs: [DisplayRecordID]
        public var destinationIDs: [DisplayRecordID]
        /// The id the destination is connected under: where moved settings are written.
        public var destinationLiveID: DisplayRecordID
        /// The registry record removed by a transfer (nil for a source without one, and for migration).
        public var sourceRecordID: DisplayRecordID?
        /// The destination's registry record, persisted or provisional.
        public var destinationRecordID: DisplayRecordID?
        public var source: SavedSettings
        public var destination: SavedSettings
        /// One per category that would change, in `Category` order.
        public var changes: [Change]
        /// What the source holds that never moves.
        public var retained: [Retained]
        /// Transfer: what the two fingerprints say. Nil for migration (one record).
        public var physicalIdentity: PhysicalIdentity?
        /// Transfer: the forget that removes the source afterwards — what it drops, exactly.
        public var sourceCleanup: RememberedDisplayCleanup.Plan?

        /// The categories a user can tick: every change except a migration conflict.
        public var selectable: [Category] {
            changes.filter { $0.effect != .conflict }.map(\.category)
        }

        /// Ticked by default: everything selectable.
        public var defaultSelection: Set<Category> { Set(selectable) }

        /// A transfer between two positively different displays — a replacement monitor — needs the
        /// user to say so explicitly before it can be applied.
        public var needsDifferentDisplayAcknowledgement: Bool {
            kind == .transfer && physicalIdentity == .differentDisplays
        }

        public func change(for category: Category) -> Change? {
            changes.first { $0.category == category }
        }

        /// What `selection` actually moves: the selectable categories in it.
        public func chosen(_ selection: Set<Category>) -> Set<Category> {
            selection.intersection(selectable)
        }
    }

    // MARK: - Reading what is saved

    /// What is saved for a display under `ids` (in the order given, which decides favourite order
    /// and which membership counts first) with `record`'s name and tags.
    public static func saved(under ids: [DisplayRecordID], record: DisplayRecord?,
                             settings: OpenDisplaySettings, favorites: FavoriteResolutions,
                             menuLayout: MenuLayoutSettings) -> SavedSettings {
        let idSet = Set(ids)
        let raw = ids.map(\.rawValue)
        var keys: [String] = []
        for id in ids { for key in favorites.favoriteKeys(for: id) where !keys.contains(key) { keys.append(key) } }
        var group: GroupMembership?
        for id in ids {
            if let found = DisplayGroupStore.group(containing: id, in: settings.displayGroups) {
                group = GroupMembership(groupID: found.id, groupName: found.name, memberID: id,
                                        offset: found.offsetByMember[id.rawValue])
                break
            }
        }
        var restores: [RememberedDisplayCleanup.PendingRestore] = []
        if raw.contains(where: { settings.faceLightPriorStateByDisplay[$0] != nil }) { restores.append(.faceLight) }
        if raw.contains(where: { settings.appPresetPriorStateByDisplay[$0] != nil }) { restores.append(.appPreset) }
        if raw.contains(where: { settings.adaptiveDayPresetByDisplay[$0] != nil }) { restores.append(.eveningColorPreset) }
        return SavedSettings(
            alias: record?.alias.flatMap { $0.isEmpty ? nil : $0 },
            tags: record?.tags ?? [],
            favoriteKeys: keys,
            menuHidden: ids.contains(where: menuLayout.isHidden),
            menuIcon: ids.lazy.compactMap { menuLayout.iconSymbol(for: $0) }.first,
            menuOrderPosition: menuLayout.displayOrder.firstIndex(where: raw.contains),
            group: group,
            softwareBrightness: raw.contains(where: settings.softwareBrightnessDisplayIDs.contains),
            adaptiveOffset: raw.lazy.compactMap { settings.adaptiveBrightnessOffsetByDisplay[$0] }.first,
            appleDDCOverride: raw.contains(where: settings.ddcAppleDisplayOverrideIDs.contains),
            ddcChannelMapping: settings.ddcChannelMappings.contains { idSet.contains($0.displayID) },
            pendingRestores: restores,
            inputSwitchHotkeys: settings.hotkeyShortcuts.inputSwitchBindings.filter { idSet.contains($0.displayID) }.count,
            appPresetNames: settings.appPresets.compactMap { preset in
                guard case .display(let target) = preset.target, raw.contains(target) else { return nil }
                return preset.applicationName
            }.sorted(),
            protectedLayoutKeys: settings.protectedLayouts.filter { _, config in
                LayoutProtectionPolicy.members(of: config).contains(where: idSet.contains)
            }.keys.sorted())
    }

    // MARK: - Planning

    /// The remembered displays a connected `destination` can take settings from: absent, removable
    /// (nothing OpenDisplay still owes them) and not possibly the connected look-alike of another
    /// display. In inventory order.
    public static func sources(for destination: RememberedDisplay,
                               among entries: [RememberedDisplay]) -> [RememberedDisplay] {
        entries.filter { (try? validate(source: $0, destination: destination)) != nil }
    }

    /// Moving `source`'s settings onto the connected `destination` (`destinationLiveID` is the id it
    /// is connected under). Throws when the pair isn't allowed — see `Refusal`.
    public static func transferPlan(
        from source: RememberedDisplay,
        to destination: RememberedDisplay,
        destinationLiveID: DisplayRecordID,
        settings: OpenDisplaySettings,
        favorites: FavoriteResolutions,
        menuLayout: MenuLayoutSettings,
        ledger: [ManagedOfflineDisplay]
    ) throws(Refusal) -> Plan {
        guard destination.observationIDs.contains(destinationLiveID) else { throw .destinationNotConnected }
        try validate(source: source, destination: destination)
        let cleanup: RememberedDisplayCleanup.Plan
        do {
            cleanup = try RememberedDisplayCleanup.plan(for: source, mode: .forget, settings: settings,
                                                        favorites: favorites, menuLayout: menuLayout, ledger: ledger)
        } catch {
            throw .sourceOwedReconnect(error)
        }
        let sourceRecord = source.isRegistered ? source.record : nil
        let destinationIDs = [destinationLiveID] + destination.observationIDs.filter { $0 != destinationLiveID }
        let from = saved(under: source.observationIDs, record: sourceRecord, settings: settings,
                         favorites: favorites, menuLayout: menuLayout)
        let to = saved(under: destinationIDs, record: destination.record, settings: settings,
                       favorites: favorites, menuLayout: menuLayout)
        // The name and tags live on registry records: there is nothing to give without a source
        // record, and nowhere to put them without a destination one.
        let registryCategories: Set<Category> = [.name, .tags]
        let changes = Category.allCases.compactMap { category -> Change? in
            if registryCategories.contains(category), sourceRecord == nil || destination.record == nil { return nil }
            return from.value(of: category) == to.value(of: category) ? nil : Change(category: category, effect: .replace)
        }
        let identity: PhysicalIdentity
        if let a = source.record?.fingerprint, let b = destination.record?.fingerprint {
            identity = FingerprintComparison.physicalIdentity(a, b)
        } else {
            identity = .undetermined
        }
        return Plan(
            kind: .transfer, sourceEntryID: source.id, destinationEntryID: destination.id,
            sourceIDs: source.observationIDs, destinationIDs: destinationIDs,
            destinationLiveID: destinationLiveID, sourceRecordID: sourceRecord?.id,
            destinationRecordID: destination.record?.id, source: from, destination: to, changes: changes,
            retained: Retained.allCases.filter(from.holds), physicalIdentity: identity, sourceCleanup: cleanup)
    }

    /// Bringing settings saved under `entry`'s earlier identifiers to the one it is connected under
    /// now (`liveID`). Throws `.nothingToMove` when no earlier identifier holds anything it lacks.
    public static func migrationPlan(
        for entry: RememberedDisplay,
        liveID: DisplayRecordID,
        settings: OpenDisplaySettings,
        favorites: FavoriteResolutions,
        menuLayout: MenuLayoutSettings
    ) throws(Refusal) -> Plan {
        guard entry.isConnected, entry.observationIDs.contains(liveID) else { throw .destinationNotConnected }
        let earlier = entry.observationIDs.filter { $0 != liveID }
        guard !earlier.isEmpty else { throw .nothingToMove }
        let from = saved(under: earlier, record: nil, settings: settings, favorites: favorites, menuLayout: menuLayout)
        let to = saved(under: [liveID], record: nil, settings: settings, favorites: favorites, menuLayout: menuLayout)
        var changes: [Change] = []
        if from.favoriteKeys.contains(where: { !to.favoriteKeys.contains($0) }) {
            changes.append(Change(category: .favoriteModes, effect: to.favoriteKeys.isEmpty ? .move : .merge))
        }
        if let group = from.group {
            if to.group == nil {
                changes.append(Change(category: .groupMembership, effect: .move))
            } else if to.group?.groupID != group.groupID {
                changes.append(Change(category: .groupMembership, effect: .conflict))
            }
        }
        if from.softwareBrightness, !to.softwareBrightness {
            changes.append(Change(category: .softwareBrightness, effect: .move))
        }
        if let offset = from.adaptiveOffset {
            if to.adaptiveOffset == nil {
                changes.append(Change(category: .adaptiveOffset, effect: .move))
            } else if to.adaptiveOffset != offset {
                changes.append(Change(category: .adaptiveOffset, effect: .conflict))
            }
        }
        guard changes.contains(where: { $0.effect != .conflict }) else { throw .nothingToMove }
        return Plan(
            kind: .migrate, sourceEntryID: entry.id, destinationEntryID: entry.id,
            sourceIDs: earlier, destinationIDs: [liveID], destinationLiveID: liveID,
            sourceRecordID: nil, destinationRecordID: entry.isRegistered ? entry.record?.id : nil,
            source: from, destination: to, changes: changes,
            retained: Retained.allCases.filter(from.holds), physicalIdentity: nil, sourceCleanup: nil)
    }

    private static func validate(source: RememberedDisplay, destination: RememberedDisplay) throws(Refusal) {
        guard destination.isConnected else { throw .destinationNotConnected }
        let sameRecord = source.record != nil && source.record?.id == destination.record?.id
        guard source.id != destination.id, !sameRecord,
              Set(source.observationIDs).isDisjoint(with: destination.observationIDs) else { throw .sameDisplay }
        if source.isConnected { throw .sourceConnected }
        if let refusal = source.forgetRefusal { throw .sourceOwedReconnect(refusal) }
        if source.mayBeConnectedDisplay {
            // The look-alike that names this record as a candidate is the one display that may take
            // it — that choice is how the ambiguity gets resolved. Any other would be a guess.
            guard let id = source.record?.id, destination.record?.unresolvedCandidates?.contains(id) == true else {
                throw .sourceMayBeConnected
            }
        }
    }

    // MARK: - Applying

    /// The registry half: what `DisplayRegistry.transferUserData` is asked to do.
    public struct RegistryChange: Hashable, Sendable {
        public var sourceRecordID: DisplayRecordID?
        public var destinationRecordID: DisplayRecordID?
        public var alias: Bool
        public var tags: Bool
    }

    public static func registryChange(_ plan: Plan, selection: Set<Category>) -> RegistryChange {
        let chosen = plan.chosen(selection)
        return RegistryChange(sourceRecordID: plan.sourceRecordID, destinationRecordID: plan.destinationRecordID,
                              alias: chosen.contains(.name), tags: chosen.contains(.tags))
    }

    public static func applying(_ plan: Plan, selection: Set<Category>,
                                to settings: OpenDisplaySettings) -> OpenDisplaySettings {
        let chosen = plan.chosen(selection)
        let live = plan.destinationLiveID
        var updated = settings
        switch plan.kind {
        case .transfer:
            if chosen.contains(.groupMembership) {
                for id in plan.destinationIDs {
                    if let group = DisplayGroupStore.group(containing: id, in: updated.displayGroups) {
                        updated.displayGroups = DisplayGroupStore.removeMember(id, from: group.id, in: updated.displayGroups)
                    }
                }
                if let membership = plan.source.group {
                    updated.displayGroups = replacing(membership, with: live, in: updated.displayGroups)
                }
            }
            if chosen.contains(.softwareBrightness) {
                updated.softwareBrightnessDisplayIDs.subtract(plan.destinationIDs.map(\.rawValue))
                if plan.source.softwareBrightness { updated.softwareBrightnessDisplayIDs.insert(live.rawValue) }
            }
            if chosen.contains(.adaptiveOffset) {
                for id in plan.destinationIDs { updated.adaptiveBrightnessOffsetByDisplay[id.rawValue] = nil }
                updated.adaptiveBrightnessOffsetByDisplay[live.rawValue] = plan.source.adaptiveOffset
            }
            if let cleanup = plan.sourceCleanup { updated = RememberedDisplayCleanup.applying(cleanup, to: updated) }
        case .migrate:
            if chosen.contains(.groupMembership), let membership = plan.source.group, plan.destination.group == nil {
                updated.displayGroups = replacing(membership, with: live, in: updated.displayGroups)
            }
            if chosen.contains(.softwareBrightness), plan.source.softwareBrightness {
                updated.softwareBrightnessDisplayIDs.subtract(plan.sourceIDs.map(\.rawValue))
                updated.softwareBrightnessDisplayIDs.insert(live.rawValue)
            }
            if chosen.contains(.adaptiveOffset), let offset = plan.source.adaptiveOffset,
               plan.destination.adaptiveOffset == nil {
                for id in plan.sourceIDs { updated.adaptiveBrightnessOffsetByDisplay[id.rawValue] = nil }
                updated.adaptiveBrightnessOffsetByDisplay[live.rawValue] = offset
            }
        }
        return updated
    }

    public static func applying(_ plan: Plan, selection: Set<Category>,
                                to favorites: FavoriteResolutions) -> FavoriteResolutions {
        let chosen = plan.chosen(selection)
        var updated = favorites
        switch plan.kind {
        case .transfer:
            if chosen.contains(.favoriteModes) {
                for id in plan.destinationIDs { updated.removeAll(for: id) }
                updated.setKeys(plan.source.favoriteKeys, for: plan.destinationLiveID)
            }
            if let cleanup = plan.sourceCleanup { updated = RememberedDisplayCleanup.applying(cleanup, to: updated) }
        case .migrate:
            if chosen.contains(.favoriteModes) {
                updated.setKeys(plan.destination.favoriteKeys + plan.source.favoriteKeys, for: plan.destinationLiveID)
                for id in plan.sourceIDs { updated.removeAll(for: id) }
            }
        }
        return updated
    }

    public static func applying(_ plan: Plan, selection: Set<Category>,
                                to layout: MenuLayoutSettings) -> MenuLayoutSettings {
        guard plan.kind == .transfer else { return layout }
        var updated = layout
        if plan.chosen(selection).contains(.menuPresentation) {
            let prefs = DisplayMenuPreferences(hidden: plan.source.menuHidden, iconSymbol: plan.source.menuIcon)
            for id in plan.destinationIDs { updated.displays[id.rawValue] = prefs.isDefault ? nil : prefs }
            // The destination takes the source's place in the manual order, or leaves it if the
            // source had none.
            let sourceKeys = Set(plan.sourceIDs.map(\.rawValue))
            let destinationKeys = Set(plan.destinationIDs.map(\.rawValue))
            var order: [String] = []
            var placed = false
            for key in updated.displayOrder where !destinationKeys.contains(key) {
                if sourceKeys.contains(key) {
                    if !placed { order.append(plan.destinationLiveID.rawValue) }
                    placed = true
                } else {
                    order.append(key)
                }
            }
            updated.displayOrder = order
        }
        if let cleanup = plan.sourceCleanup { updated = RememberedDisplayCleanup.applying(cleanup, to: updated) }
        return updated
    }

    /// The ledger after the plan: a transfer drops the source's entry, as Forget does.
    public static func applying(_ plan: Plan, to ledger: [ManagedOfflineDisplay]) -> [ManagedOfflineDisplay] {
        guard let cleanup = plan.sourceCleanup else { return ledger }
        return RememberedDisplayCleanup.applying(cleanup, to: ledger)
    }

    /// `membership`'s group with `live` in the member's place — same position, same offset.
    private static func replacing(_ membership: GroupMembership, with live: DisplayRecordID,
                                  in groups: [DisplayGroup]) -> [DisplayGroup] {
        groups.map { group in
            guard group.id == membership.groupID,
                  let index = group.memberRecordIDs.firstIndex(of: membership.memberID) else { return group }
            var edited = group
            edited.memberRecordIDs[index] = live
            edited.offsetByMember[membership.memberID.rawValue] = nil
            if let offset = membership.offset { edited.offsetByMember[live.rawValue] = offset }
            return edited
        }
    }
}
