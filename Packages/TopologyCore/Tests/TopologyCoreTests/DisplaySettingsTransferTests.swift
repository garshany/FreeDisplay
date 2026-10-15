import XCTest
import AutomationSchema
import DisplayDomain
@testable import TopologyCore

/// SD-10 / FA-11 / TB-09: moving saved settings between identities is previewed exactly, replaces
/// rather than merges on a transfer, fills in only what is missing on a migration, never merges two
/// identities, and leaves behind — listed — what must not move.
final class DisplaySettingsTransferTests: XCTestCase {
    private let old = DisplayRecordID.forCGUUID("OLD")
    private let new = DisplayRecordID.forCGUUID("NEW")
    private let newOtherPort = DisplayRecordID.forCGUUID("NEW-2")
    private let other = DisplayRecordID.forCGUUID("OTHER")

    private func mode(_ width: Int) -> DisplayMode {
        DisplayMode(pixelWidth: width, pixelHeight: 1080, pointWidth: width, pointHeight: 1080,
                    refreshHz: 60, isHiDPI: false)
    }

    private func record(_ id: String, serial: String?, alias: String? = nil, tags: Set<String> = [],
                        candidates: [DisplayRecordID]? = nil) -> DisplayRecord {
        DisplayRecord(id: .init(rawValue: id), alias: alias, tags: tags,
                      fingerprint: DisplayFingerprint(vendorID: 1, productID: 1, serialNumber: serial),
                      displayClass: .external, unresolvedCandidates: candidates)
    }

    private func oldEntry(status: RememberedDisplay.Status = .notConnected, serial: String? = "S-OLD",
                          ledger: [ManagedOfflineDisplay] = [], mayBeConnected: Bool = false) -> RememberedDisplay {
        RememberedDisplay(id: "disp_old", record: record("disp_old", serial: serial, alias: "Desk", tags: ["studio"]),
                          isRegistered: true, observationIDs: [old], status: status, offlineEntries: ledger,
                          mayBeConnectedDisplay: mayBeConnected)
    }

    private func newEntry(serial: String? = "S-NEW", ids: [DisplayRecordID]? = nil,
                          candidates: [DisplayRecordID]? = nil) -> RememberedDisplay {
        RememberedDisplay(id: "disp_new", record: record("disp_new", serial: serial, alias: "Fresh", tags: ["temp"],
                                                         candidates: candidates),
                          isRegistered: candidates == nil, observationIDs: ids ?? [new], status: .connected,
                          offlineEntries: [])
    }

    private func layout(_ ids: [DisplayRecordID]) -> ProtectedConfig {
        ProtectedConfig(snapshot: TopologySnapshot(
            generation: .init(1),
            observations: ids.map { DisplayObservation(recordID: $0, cgDisplayID: 1, isActive: true,
                                                       displayClass: .external, generation: .initial) }),
                        capturedAt: Date(timeIntervalSince1970: 0))
    }

    private let groupA = UUID()
    private let groupB = UUID()

    /// `old` has something of every kind; `new` has its own values in most of them.
    private func populated() -> (OpenDisplaySettings, FavoriteResolutions, MenuLayoutSettings) {
        var settings = OpenDisplaySettings()
        settings.displayGroups = [
            DisplayGroup(id: groupA, name: "Desk pair", memberRecordIDs: [other, old],
                         offsetByMember: [other.rawValue: 0, old.rawValue: 0.2]),
            DisplayGroup(id: groupB, name: "Elsewhere", memberRecordIDs: [new], offsetByMember: [new.rawValue: -0.1]),
        ]
        settings.defaultDisplayGroup.offsetByMember[old.rawValue] = 0.15
        settings.luminanceAnchorsByDisplay = [old.rawValue: .init(manualValuesEnabled: false,
            overrides: [.sdrMaximum: .init(nits: 320, basis: .specification)])]
        settings.keyboardAudioByDisplay = [old.rawValue: .init(keyboardControl: false, nativeAudioEnabled: true,
                                                              nativeAudioDevice: "USB")]
        settings.preventDisplaySleepDisplayIDs = [old.rawValue]
        settings.osdFeedback.volumeHiddenDisplayIDs = [old.rawValue]
        settings.softwareBrightnessDisplayIDs = [old.rawValue]
        settings.ddcAppleDisplayOverrideIDs = [old.rawValue]
        settings.ddcChannelMappings = [DDCChannelMapping(
            displayID: old, displayIdentity: .init(vendorNumber: 1, productNumber: 1, serialNumber: 0),
            channelPath: "IOService:/dcpext0/DCPAVServiceProxy", channelAttributes: nil,
            confirmedAt: Date(timeIntervalSince1970: 0))]
        settings.adaptiveBrightnessOffsetByDisplay = [old.rawValue: 0.3, new.rawValue: -0.2]
        settings.faceLightPriorStateByDisplay = [old.rawValue: .init(brightness: 0.4)]
        settings.protectedLayouts = ["old-desk": layout([old, other]), "new-desk": layout([new])]
        settings.hotkeyShortcuts.addInputSwitchBinding(
            InputSwitchBinding(displayID: old, inputCode: 0x11, binding: KeyBinding(keyCode: 1, modifiers: 2)))
        settings.appPresets = [.init(bundleIdentifier: "com.example.photo", applicationName: "Photo",
                                     brightness: 0.9, target: .display(old.rawValue))]
        var favorites = FavoriteResolutions()
        favorites.add(mode(1920), for: old)
        favorites.add(mode(2560), for: old)
        favorites.add(mode(1280), for: new)
        var menu = MenuLayoutSettings()
        menu.setIconSymbol("display.2", for: [old])
        menu.setHidden(true, for: [new])
        menu.displayOrder = [new.rawValue, other.rawValue, old.rawValue]
        return (settings, favorites, menu)
    }

    private func transferPlan(source: RememberedDisplay? = nil, destination: RememberedDisplay? = nil,
                              liveID: DisplayRecordID? = nil) throws -> DisplaySettingsTransfer.Plan {
        let (settings, favorites, menu) = populated()
        return try DisplaySettingsTransfer.transferPlan(
            from: source ?? oldEntry(), to: destination ?? newEntry(), destinationLiveID: liveID ?? new,
            settings: settings, favorites: favorites, menuLayout: menu, ledger: [])
    }

    func testPreviewIncludesEveryIdentifierAndDetectsHiddenRelationshipChanges() throws {
        var (settings, favorites, menu) = populated()
        var destination = newEntry()
        let earlier = DisplayRecordID.forCGUUID("another-port")
        destination.observationIDs.append(earlier)
        settings.displayGroups[0].memberRecordIDs.append(earlier)
        menu.setIconSymbol("star", for: [earlier])
        let first = try DisplaySettingsTransfer.transferPlan(from: oldEntry(), to: destination,
            destinationLiveID: new, settings: settings, favorites: favorites, menuLayout: menu, ledger: [])
        XCTAssertEqual(first.destinationByID[earlier]?.group?.groupName, "Desk pair")
        XCTAssertEqual(first.destinationByID[earlier]?.menuIcon, "star")
        menu.setIconSymbol("circle", for: [earlier])
        let changed = try DisplaySettingsTransfer.transferPlan(from: oldEntry(), to: destination,
            destinationLiveID: new, settings: settings, favorites: favorites, menuLayout: menu, ledger: [])
        XCTAssertNotEqual(first, changed)
    }

    // MARK: - Transfer: what may be moved where

    func testOnlyAnAbsentRemovableRecordCanBeTheSource() {
        let (settings, favorites, menu) = populated()
        func refusal(_ source: RememberedDisplay, _ destination: RememberedDisplay,
                     live: DisplayRecordID? = nil) -> DisplaySettingsTransfer.Refusal? {
            do {
                _ = try DisplaySettingsTransfer.transferPlan(
                    from: source, to: destination, destinationLiveID: live ?? destination.observationIDs[0],
                    settings: settings, favorites: favorites, menuLayout: menu, ledger: [])
                return nil
            } catch {
                return error
            }
        }
        var connectedOld = oldEntry()
        connectedOld.status = .connected
        XCTAssertEqual(refusal(connectedOld, newEntry()), .sourceConnected)
        XCTAssertEqual(refusal(oldEntry(status: .turnedOff), newEntry()), .sourceOwedReconnect(.turnedOffByApp))
        let builtIn = ManagedOfflineDisplay(recordID: old, cgID: 1, name: "Built-in", displayClass: .builtIn,
                                            reconnectFailedAt: Date())
        XCTAssertEqual(refusal(oldEntry(status: .reconnectFailed, ledger: [builtIn]), newEntry()),
                       .sourceOwedReconnect(.builtInTurnedOff))
        XCTAssertEqual(refusal(oldEntry(), oldEntry()), .destinationNotConnected)
        var sameRecord = newEntry()
        sameRecord.status = .notConnected
        sameRecord.id = "other-entry"
        sameRecord.observationIDs = [other]
        XCTAssertEqual(refusal(sameRecord, newEntry()), .sameDisplay, "two ids of one record are a migration")
        XCTAssertEqual(refusal(oldEntry(mayBeConnected: true), newEntry()), .sourceMayBeConnected)
        XCTAssertNil(refusal(oldEntry(mayBeConnected: true),
                             newEntry(candidates: [DisplayRecordID(rawValue: "disp_old")])),
                     "the look-alike naming it as a candidate may take it — that resolves the ambiguity")
        XCTAssertEqual(refusal(oldEntry(), newEntry(), live: other), .destinationNotConnected)
    }

    func testSourcesListsOnlyEligibleRecords() {
        var turnedOff = oldEntry(status: .turnedOff)
        turnedOff.id = "turned-off"
        turnedOff.observationIDs = [other]
        let entries = [newEntry(), oldEntry(), turnedOff]
        XCTAssertEqual(DisplaySettingsTransfer.sources(for: newEntry(), among: entries).map(\.id), ["disp_old"])
    }

    // MARK: - Transfer: the preview

    func testThePreviewListsEveryDifferenceAndWhatStaysBehind() throws {
        let plan = try transferPlan()
        XCTAssertEqual(plan.kind, .transfer)
        XCTAssertEqual(plan.changes.map(\.category), DisplaySettingsTransfer.Category.allCases)
        XCTAssertTrue(plan.changes.allSatisfy { $0.effect == .replace })
        XCTAssertEqual(plan.source.alias, "Desk")
        XCTAssertEqual(plan.destination.alias, "Fresh")
        XCTAssertEqual(plan.source.favoriteKeys.count, 2)
        XCTAssertEqual(plan.source.group?.groupName, "Desk pair")
        XCTAssertEqual(plan.destination.group?.groupName, "Elsewhere")
        XCTAssertEqual(plan.retained, [.appleDDCOverride, .ddcChannelMapping, .pendingRestores, .inputSwitchHotkeys,
                                       .appPresets, .protectedLayouts])
        XCTAssertEqual(plan.sourceCleanup?.ddcChannelMapping, true)
        XCTAssertEqual(plan.sourceCleanup?.protectedLayoutKeys, ["old-desk"])
        XCTAssertEqual(plan.sourceRecordID?.rawValue, "disp_old")
        XCTAssertEqual(plan.defaultSelection, Set(DisplaySettingsTransfer.Category.allCases))
    }

    func testIdenticalValuesAreNotListedAsChanges() throws {
        let (settings, favorites, menu) = populated()
        var same = settings
        same.adaptiveBrightnessOffsetByDisplay[new.rawValue] = 0.3
        let plan = try DisplaySettingsTransfer.transferPlan(
            from: oldEntry(), to: newEntry(), destinationLiveID: new,
            settings: same, favorites: favorites, menuLayout: menu, ledger: [])
        XCTAssertNil(plan.change(for: .adaptiveOffset))
    }

    func testNameAndTagsNeedARecordOnBothSides() throws {
        var bare = oldEntry()
        bare.isRegistered = false
        let plan = try transferPlan(source: bare)
        XCTAssertNil(plan.change(for: .name))
        XCTAssertNil(plan.change(for: .tags))
        XCTAssertNil(plan.sourceRecordID)
    }

    /// A replacement monitor is allowed, but never silently: the plan says they are two displays.
    func testPhysicalIdentityDecidesWhetherAcknowledgementIsNeeded() throws {
        XCTAssertEqual(try transferPlan().physicalIdentity, .differentDisplays)
        XCTAssertTrue(try transferPlan().needsDifferentDisplayAcknowledgement)
        let unknown = try transferPlan(source: oldEntry(serial: nil))
        XCTAssertEqual(unknown.physicalIdentity, .undetermined)
        XCTAssertFalse(unknown.needsDifferentDisplayAcknowledgement)
    }

    // MARK: - Transfer: applying

    func testApplyingReplacesTheDestinationAndRemovesTheSource() throws {
        let plan = try transferPlan()
        let (settings, favorites, menu) = populated()
        let all = plan.defaultSelection

        let updated = DisplaySettingsTransfer.applying(plan, selection: all, to: settings)
        let pair = updated.displayGroups.first { $0.id == groupA }
        XCTAssertEqual(pair?.memberRecordIDs, [other, new], "takes the source's place in its group")
        XCTAssertEqual(pair?.offset(for: new), 0.2)
        XCTAssertEqual(updated.displayGroups.first { $0.id == groupB }?.memberRecordIDs, [], "and leaves its own")
        XCTAssertEqual(updated.softwareBrightnessDisplayIDs, [new.rawValue])
        XCTAssertEqual(updated.adaptiveBrightnessOffsetByDisplay, [new.rawValue: 0.3])
        XCTAssertTrue(updated.ddcAppleDisplayOverrideIDs.isEmpty, "a safety consent never moves; it goes with the source")
        XCTAssertTrue(updated.ddcChannelMappings.isEmpty, "a hand-paired channel never moves; it goes with the source")
        XCTAssertEqual(Array(updated.protectedLayouts.keys), ["new-desk"])
        XCTAssertNotNil(updated.faceLightPriorStateByDisplay[old.rawValue], "a pending restore stays where it was")
        XCTAssertEqual(updated.hotkeyShortcuts.inputSwitchBindings.map(\.displayID), [old], "rules are not retargeted")

        let favs = DisplaySettingsTransfer.applying(plan, selection: all, to: favorites)
        XCTAssertEqual(favs.favoriteKeys(for: new), favorites.favoriteKeys(for: old), "replaced, not merged")
        XCTAssertTrue(favs.favoriteKeys(for: old).isEmpty)

        let layout = DisplaySettingsTransfer.applying(plan, selection: all, to: menu)
        XCTAssertFalse(layout.isHidden(new))
        XCTAssertEqual(layout.iconSymbol(for: new), "display.2")
        XCTAssertEqual(layout.displayOrder, [other.rawValue, new.rawValue])
        XCTAssertFalse(layout.remembers([old]))
    }

    func testUnselectedCategoriesKeepTheDestinationsOwnValues() throws {
        let plan = try transferPlan()
        let (settings, favorites, menu) = populated()
        let updated = DisplaySettingsTransfer.applying(plan, selection: [.favoriteModes], to: settings)
        XCTAssertEqual(updated.displayGroups.first { $0.id == groupB }?.memberRecordIDs, [new])
        XCTAssertEqual(updated.displayGroups.first { $0.id == groupA }?.memberRecordIDs, [other],
                       "the source still leaves, as with Forget")
        XCTAssertTrue(updated.softwareBrightnessDisplayIDs.isEmpty)
        XCTAssertEqual(updated.adaptiveBrightnessOffsetByDisplay, [new.rawValue: -0.2])
        let layout = DisplaySettingsTransfer.applying(plan, selection: [.favoriteModes], to: menu)
        XCTAssertTrue(layout.isHidden(new))
        XCTAssertEqual(layout.displayOrder, [new.rawValue, other.rawValue])
        let favs = DisplaySettingsTransfer.applying(plan, selection: [], to: favorites)
        XCTAssertEqual(favs.favoriteKeys(for: new), favorites.favoriteKeys(for: new))
        XCTAssertTrue(favs.favoriteKeys(for: old).isEmpty)
        let registry = DisplaySettingsTransfer.registryChange(plan, selection: [.tags])
        XCTAssertEqual(registry, .init(sourceRecordID: .init(rawValue: "disp_old"),
                                       destinationRecordID: .init(rawValue: "disp_new"), alias: false, tags: true))
    }

    func testAReplacedValueCanBeNothing() throws {
        let (settings, favorites, menu) = populated()
        var plain = settings
        plain.adaptiveBrightnessOffsetByDisplay[old.rawValue] = nil
        let plan = try DisplaySettingsTransfer.transferPlan(
            from: oldEntry(), to: newEntry(), destinationLiveID: new,
            settings: plain, favorites: favorites, menuLayout: menu, ledger: [])
        XCTAssertEqual(plan.change(for: .adaptiveOffset)?.effect, .replace)
        let updated = DisplaySettingsTransfer.applying(plan, selection: [.adaptiveOffset], to: plain)
        XCTAssertNil(updated.adaptiveBrightnessOffsetByDisplay[new.rawValue])
    }

    func testATransferDropsTheSourcesFailedReconnectCard() throws {
        let failed = ManagedOfflineDisplay(recordID: old, cgID: 4, name: "Desk", displayClass: .external,
                                           reconnectFailedAt: Date())
        let (settings, favorites, menu) = populated()
        let plan = try DisplaySettingsTransfer.transferPlan(
            from: oldEntry(status: .reconnectFailed, ledger: [failed]), to: newEntry(), destinationLiveID: new,
            settings: settings, favorites: favorites, menuLayout: menu, ledger: [failed])
        XCTAssertEqual(plan.sourceCleanup?.removesTurnedOffRecord, true)
        XCTAssertTrue(DisplaySettingsTransfer.applying(plan, to: [failed]).isEmpty)
    }

    func testTheDestinationsOtherIdentifiersAreReplacedToo() throws {
        let (settings, favorites, menu) = populated()
        var moreFavorites = favorites
        moreFavorites.add(mode(800), for: newOtherPort)
        let plan = try DisplaySettingsTransfer.transferPlan(
            from: oldEntry(), to: newEntry(ids: [new, newOtherPort]), destinationLiveID: newOtherPort,
            settings: settings, favorites: moreFavorites, menuLayout: menu, ledger: [])
        XCTAssertEqual(plan.destinationIDs, [newOtherPort, new], "the live id first")
        let favs = DisplaySettingsTransfer.applying(plan, selection: [.favoriteModes], to: moreFavorites)
        XCTAssertTrue(favs.favoriteKeys(for: new).isEmpty)
        XCTAssertEqual(favs.favoriteKeys(for: newOtherPort), favorites.favoriteKeys(for: old))
    }

    // MARK: - Migration

    private func migrating() -> (RememberedDisplay, OpenDisplaySettings, FavoriteResolutions, MenuLayoutSettings) {
        let entry = RememberedDisplay(id: "disp_desk", record: record("disp_desk", serial: "S", alias: "Desk"),
                                      isRegistered: true, observationIDs: [new, old], status: .connected,
                                      offlineEntries: [])
        var settings = OpenDisplaySettings()
        settings.displayGroups = [DisplayGroup(id: groupA, name: "Desk pair", memberRecordIDs: [old, other],
                                               offsetByMember: [old.rawValue: 0.2])]
        settings.softwareBrightnessDisplayIDs = [old.rawValue]
        settings.adaptiveBrightnessOffsetByDisplay = [old.rawValue: 0.3]
        settings.ddcAppleDisplayOverrideIDs = [old.rawValue]
        var favorites = FavoriteResolutions()
        favorites.add(mode(1920), for: old)
        favorites.add(mode(1280), for: new)
        return (entry, settings, favorites, MenuLayoutSettings())
    }

    func testMigrationFillsInWhatTheDisplayLacksUnderItsLiveIdentifier() throws {
        let (entry, settings, favorites, menu) = migrating()
        let plan = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new, settings: settings,
                                                             favorites: favorites, menuLayout: menu)
        XCTAssertEqual(plan.kind, .migrate)
        XCTAssertEqual(plan.sourceIDs, [old])
        XCTAssertEqual(plan.changes, [
            .init(category: .favoriteModes, effect: .merge),
            .init(category: .groupMembership, effect: .move),
            .init(category: .softwareBrightness, effect: .move),
            .init(category: .adaptiveOffset, effect: .move),
        ])
        XCTAssertEqual(plan.retained, [.appleDDCOverride])
        XCTAssertNil(plan.physicalIdentity)
        XCTAssertNil(plan.sourceCleanup, "nothing is forgotten by a migration")

        let all = plan.defaultSelection
        let updated = DisplaySettingsTransfer.applying(plan, selection: all, to: settings)
        XCTAssertEqual(updated.displayGroups.first?.memberRecordIDs, [new, other], "same place in the group")
        XCTAssertEqual(updated.displayGroups.first?.offset(for: new), 0.2)
        XCTAssertEqual(updated.softwareBrightnessDisplayIDs, [new.rawValue])
        XCTAssertEqual(updated.adaptiveBrightnessOffsetByDisplay, [new.rawValue: 0.3])
        XCTAssertEqual(updated.ddcAppleDisplayOverrideIDs, [old.rawValue], "the consent stays where it was given")

        let favs = DisplaySettingsTransfer.applying(plan, selection: all, to: favorites)
        XCTAssertEqual(favs.favoriteKeys(for: new),
                       favorites.favoriteKeys(for: new) + favorites.favoriteKeys(for: old), "the display's own first")
        XCTAssertTrue(favs.favoriteKeys(for: old).isEmpty)
        XCTAssertEqual(DisplaySettingsTransfer.applying(plan, selection: all, to: menu), menu)
    }

    func testMigrationNeverOverwritesTheDisplaysOwnValues() throws {
        let (start, initial, favorites, menu) = migrating()
        var entry = start
        var settings = initial
        settings.displayGroups.append(DisplayGroup(id: groupB, name: "Other", memberRecordIDs: [new]))
        settings.adaptiveBrightnessOffsetByDisplay[new.rawValue] = -0.5
        let plan = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new, settings: settings,
                                                             favorites: favorites, menuLayout: menu)
        XCTAssertEqual(plan.change(for: .groupMembership)?.effect, .conflict)
        XCTAssertEqual(plan.change(for: .adaptiveOffset)?.effect, .conflict)
        XCTAssertFalse(plan.selectable.contains(.groupMembership))
        let updated = DisplaySettingsTransfer.applying(plan, selection: Set(DisplaySettingsTransfer.Category.allCases),
                                                       to: settings)
        XCTAssertEqual(updated.displayGroups.map(\.memberRecordIDs), [[old, other], [new]],
                       "a conflicting earlier value stays where it was")
        XCTAssertEqual(updated.adaptiveBrightnessOffsetByDisplay[old.rawValue], 0.3)
        XCTAssertEqual(updated.adaptiveBrightnessOffsetByDisplay[new.rawValue], -0.5)
        entry.observationIDs = [new]
        XCTAssertThrowsError(try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new, settings: settings,
                                                                       favorites: favorites, menuLayout: menu))
    }

    func testConflictOnlyMigrationStillOffersAnInspectionPlan() throws {
        let (entry, _, _, menu) = migrating()
        var settings = OpenDisplaySettings()
        settings.adaptiveBrightnessOffsetByDisplay = [old.rawValue: 0.3, new.rawValue: 0.8]
        let plan = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new,
            settings: settings, favorites: FavoriteResolutions(), menuLayout: menu)
        XCTAssertEqual(plan.changes, [.init(category: .adaptiveOffset, effect: .conflict)])
        XCTAssertTrue(plan.selectable.isEmpty)
        XCTAssertEqual(DisplaySettingsTransfer.applying(plan, selection: Set(DisplaySettingsTransfer.Category.allCases), to: settings), settings)
    }

    func testConflictingEarlierIdentifiersRequireExplicitSourceAndPreserveAlternatives() throws {
        var (entry, settings, favorites, menu) = migrating()
        entry.observationIDs.append(newOtherPort)
        let a = LuminanceAnchorSettings(manualValuesEnabled: false)
        let b = LuminanceAnchorSettings(overrides: [.sdrMaximum: .init(nits: 500, basis: .specification)])
        settings.luminanceAnchorsByDisplay = [old.rawValue: a, newOtherPort.rawValue: b]
        settings.keyboardAudioByDisplay = [old.rawValue: .init(nativeAudioDevice: "USB-A"),
                                           newOtherPort.rawValue: .init(nativeAudioDevice: "USB-B")]
        settings.adaptiveBrightnessOffsetByDisplay = [old.rawValue: 0.1, newOtherPort.rawValue: 0.2]
        settings.defaultDisplayGroup.offsetByMember = [old.rawValue: 0.1, newOtherPort.rawValue: 0.2]
        let plan = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new, settings: settings,
                                                             favorites: favorites, menuLayout: menu)
        for category in [DisplaySettingsTransfer.Category.luminanceAnchors, .keyboardAudio, .adaptiveOffset, .defaultGroupOffset] {
            XCTAssertEqual(plan.change(for: category)?.effect, .conflict)
        }
        let unchanged = DisplaySettingsTransfer.applying(plan, selection: plan.defaultSelection, to: settings)
        XCTAssertEqual(unchanged.luminanceAnchorsByDisplay, settings.luminanceAnchorsByDisplay)
        let selected = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new, settings: settings,
            favorites: favorites, menuLayout: menu, sourceID: old)
        let moved = DisplaySettingsTransfer.applying(selected, selection: selected.defaultSelection, to: settings)
        XCTAssertEqual(moved.luminanceAnchorsByDisplay, [new.rawValue: a, newOtherPort.rawValue: b])
        XCTAssertEqual(moved.keyboardAudioByDisplay[newOtherPort.rawValue]?.nativeAudioDevice, "USB-B")
        XCTAssertEqual(moved.adaptiveBrightnessOffsetByDisplay[newOtherPort.rawValue], 0.2)
        XCTAssertEqual(moved.defaultDisplayGroup.offsetByMember[newOtherPort.rawValue], 0.2)
    }

    func testMigratingAudioBindingAlonePreservesEarlierFeedbackChoice() throws {
        var (entry, settings, favorites, menu) = migrating()
        settings.keyboardAudioByDisplay[old.rawValue] = .init(nativeAudioDevice: "USB", showsVolumeOSD: false)
        let plan = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new, settings: settings,
            favorites: favorites, menuLayout: menu)
        let moved = DisplaySettingsTransfer.applying(plan, selection: [.keyboardAudio], to: settings)
        XCTAssertEqual(moved.keyboardAudioPreferences(for: new).nativeAudioDevice, "USB")
        XCTAssertTrue(moved.showsVolumeFeedback(for: new))
        XCTAssertFalse(moved.showsVolumeFeedback(for: old), "the unselected feedback setting stays under its old ID")
    }

    func testVolumeFeedbackTransfersEffectiveValueWithoutReplacingAudioBinding() throws {
        var (settings, favorites, menu) = populated()
        settings.osdFeedback.volumeHiddenDisplayIDs = [new.rawValue]
        settings.keyboardAudioByDisplay = [new.rawValue: .init(nativeAudioDevice: "KEEP", showsVolumeOSD: false)]
        var plan = try DisplaySettingsTransfer.transferPlan(from: oldEntry(), to: newEntry(), destinationLiveID: new,
            settings: settings, favorites: favorites, menuLayout: menu, ledger: [])
        XCTAssertFalse(plan.source.volumeFeedback)
        XCTAssertTrue(plan.destination.volumeFeedback)
        let moved = DisplaySettingsTransfer.applying(plan, selection: [.volumeFeedback], to: settings)
        XCTAssertTrue(moved.showsVolumeFeedback(for: new))
        XCTAssertEqual(moved.keyboardAudioPreferences(for: new).nativeAudioDevice, "KEEP")
        settings.keyboardAudioByDisplay[old.rawValue] = .init(showsVolumeOSD: false)
        settings.osdFeedback.volumeHiddenDisplayIDs = []
        plan = try DisplaySettingsTransfer.transferPlan(from: oldEntry(), to: newEntry(), destinationLiveID: new,
            settings: settings, favorites: favorites, menuLayout: menu, ledger: [])
        XCTAssertTrue(plan.source.volumeFeedback)
    }

    func testNothingToMigrateIsSaidSo() {
        let (entry, _, _, menu) = migrating()
        XCTAssertThrowsError(try DisplaySettingsTransfer.migrationPlan(
            for: entry, liveID: new, settings: OpenDisplaySettings(), favorites: FavoriteResolutions(),
            menuLayout: menu)) { error in
            XCTAssertEqual(error as? DisplaySettingsTransfer.Refusal, .nothingToMove)
        }
        var absent = entry
        absent.status = .notConnected
        XCTAssertThrowsError(try DisplaySettingsTransfer.migrationPlan(
            for: absent, liveID: new, settings: OpenDisplaySettings(), favorites: FavoriteResolutions(),
            menuLayout: menu)) { error in
            XCTAssertEqual(error as? DisplaySettingsTransfer.Refusal, .destinationNotConnected)
        }
    }
    func testClockRecipesAreExplicitlyExcludedFromRetargetingAndIncludedInPreview() throws {
        var (settings, favorites, menu) = populated()
        settings.clockMode = .init(timeZoneIdentifier: "Europe/Moscow", resumePolicy: .pauseUntilResumed,
            displays: [old, new, other].map {
                .init(displayID: $0, entries: [], method: .software,
                      restoreLevel: AutomationLevel(normalized: 0.4)!, rampMinutes: 0)
            })
        let transfer = try DisplaySettingsTransfer.transferPlan(from: oldEntry(), to: newEntry(),
            destinationLiveID: new, settings: settings, favorites: favorites, menuLayout: menu, ledger: [])
        XCTAssertTrue(transfer.retained.contains(.clockRecipes))
        XCTAssertEqual(transfer.sourceCleanup?.clockRecipeCount, 1)
        XCTAssertEqual(transfer.source.clockRecipes.map(\.displayID), [old])
        var changed = settings
        changed.clockMode?.displays[0].rampMinutes = 7
        let refreshed = try DisplaySettingsTransfer.transferPlan(from: oldEntry(), to: newEntry(),
            destinationLiveID: new, settings: changed, favorites: favorites, menuLayout: menu, ledger: [])
        XCTAssertNotEqual(transfer.sourceByID, refreshed.sourceByID, "changed recipes invalidate the preview")
        let moved = DisplaySettingsTransfer.applying(transfer, selection: transfer.defaultSelection, to: settings)
        XCTAssertEqual(moved.clockMode?.displays, settings.clockMode?.displays.filter { $0.displayID != old })
        XCTAssertEqual(moved.clockMode?.timeZoneIdentifier, "Europe/Moscow")
        let (entry, base, migrationFavorites, migrationMenu) = migrating()
        var migratingSettings = base
        migratingSettings.clockMode = settings.clockMode
        let migration = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new,
            settings: migratingSettings, favorites: migrationFavorites, menuLayout: migrationMenu)
        XCTAssertTrue(migration.retained.contains(.clockRecipes))
        XCTAssertEqual(DisplaySettingsTransfer.applying(migration, selection: migration.defaultSelection,
            to: migratingSettings).clockMode, settings.clockMode)
    }

    func testTransferMovesMergedPreferencesAndClearsEveryDestinationAlias() throws {
        var (settings, favorites, menu) = populated()
        let anchor = LuminanceAnchorSettings(manualValuesEnabled: false,
            overrides: [.sdrMaximum: .init(nits: 320, basis: .specification)])
        let audio = settings.keyboardAudioByDisplay[old.rawValue]
        settings.luminanceAnchorsByDisplay[newOtherPort.rawValue] = .init()
        settings.keyboardAudioByDisplay[newOtherPort.rawValue] = .init(nativeAudioDevice: "other")
        var destination = newEntry()
        destination.observationIDs.append(newOtherPort)
        let plan = try DisplaySettingsTransfer.transferPlan(from: oldEntry(), to: destination, destinationLiveID: new,
            settings: settings, favorites: favorites, menuLayout: menu, ledger: [])
        XCTAssertEqual(plan.source.luminanceAnchors, anchor)
        XCTAssertEqual(plan.source.keyboardAudio, audio)
        XCTAssertTrue(plan.source.keepAwake)
        XCTAssertTrue(plan.source.volumeFeedback)
        let moved = DisplaySettingsTransfer.applying(plan, selection: plan.defaultSelection, to: settings)
        XCTAssertEqual(moved.luminanceAnchorsByDisplay, [new.rawValue: anchor])
        var effectiveAudio = try XCTUnwrap(audio)
        effectiveAudio.showsVolumeOSD = false
        XCTAssertEqual(moved.keyboardAudioByDisplay, [new.rawValue: effectiveAudio])
        XCTAssertEqual(moved.preventDisplaySleepDisplayIDs, [new.rawValue])
        XCTAssertFalse(moved.showsVolumeFeedback(for: new))
        XCTAssertTrue(moved.osdFeedback.volumeHiddenDisplayIDs.isEmpty)
        XCTAssertTrue(moved.ddcChannelMappings.isEmpty, "physical pairing is never retargeted")
        XCTAssertEqual(moved.defaultDisplayGroup.offsetByMember, [new.rawValue: 0.15])
        let skipped = DisplaySettingsTransfer.applying(plan, selection: [], to: settings)
        XCTAssertNil(skipped.luminanceAnchorsByDisplay[old.rawValue], "source is forgotten even if a category is skipped")
        XCTAssertEqual(skipped.luminanceAnchorsByDisplay[newOtherPort.rawValue], .init())
        XCTAssertEqual(skipped.keyboardAudioByDisplay[newOtherPort.rawValue]?.nativeAudioDevice, "other")
    }

    func testTransferCanClearMergedDestinationPreferences() throws {
        let (initial, favorites, menu) = populated()
        var settings = initial
        settings.luminanceAnchorsByDisplay = [new.rawValue: .init(manualValuesEnabled: false)]
        settings.keyboardAudioByDisplay = [new.rawValue: .init(keyboardControl: false)]
        settings.preventDisplaySleepDisplayIDs = [new.rawValue]
        settings.osdFeedback.volumeHiddenDisplayIDs = [new.rawValue]
        let plan = try DisplaySettingsTransfer.transferPlan(from: oldEntry(), to: newEntry(), destinationLiveID: new,
            settings: settings, favorites: favorites, menuLayout: menu, ledger: [])
        let cleared = DisplaySettingsTransfer.applying(plan, selection: plan.defaultSelection, to: settings)
        XCTAssertTrue(cleared.luminanceAnchorsByDisplay.isEmpty)
        XCTAssertTrue(cleared.keyboardAudioByDisplay.isEmpty)
        XCTAssertTrue(cleared.preventDisplaySleepDisplayIDs.isEmpty)
        XCTAssertTrue(cleared.osdFeedback.volumeHiddenDisplayIDs.isEmpty)
    }

    func testMigrationMovesMergedPreferencesButPreservesConflictsAndPreviewEvidence() throws {
        var (entry, settings, favorites, menu) = migrating()
        let anchors = LuminanceAnchorSettings(manualValuesEnabled: false)
        settings.defaultDisplayGroup.offsetByMember[old.rawValue] = 0.25
        let audio = DisplayKeyboardAudioPreferences(keyboardControl: false, nativeAudioDevice: "USB")
        settings.luminanceAnchorsByDisplay[old.rawValue] = anchors
        settings.keyboardAudioByDisplay[old.rawValue] = audio
        settings.preventDisplaySleepDisplayIDs.insert(old.rawValue)
        settings.osdFeedback.volumeHiddenDisplayIDs.insert(old.rawValue)
        let plan = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new, settings: settings,
            favorites: favorites, menuLayout: menu)
        for category in [DisplaySettingsTransfer.Category.defaultGroupOffset, .luminanceAnchors, .keyboardAudio, .keepAwake, .volumeFeedback] {
            XCTAssertEqual(plan.change(for: category)?.effect, .move)
        }
        let moved = DisplaySettingsTransfer.applying(plan, selection: plan.defaultSelection, to: settings)
        XCTAssertEqual(moved.luminanceAnchorsByDisplay, [new.rawValue: anchors])
        XCTAssertEqual(moved.defaultDisplayGroup.offsetByMember, [new.rawValue: 0.25])
        var effectiveAudio = audio
        effectiveAudio.showsVolumeOSD = false
        XCTAssertEqual(moved.keyboardAudioByDisplay, [new.rawValue: effectiveAudio])
        XCTAssertEqual(moved.preventDisplaySleepDisplayIDs, [new.rawValue])
        XCTAssertFalse(moved.showsVolumeFeedback(for: new))
        XCTAssertTrue(moved.osdFeedback.volumeHiddenDisplayIDs.isEmpty)
        settings.keyboardAudioByDisplay[new.rawValue] = .init(nativeAudioEnabled: true)
        settings.luminanceAnchorsByDisplay[new.rawValue] = .init()
        let conflicting = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new, settings: settings,
            favorites: favorites, menuLayout: menu)
        XCTAssertEqual(conflicting.change(for: .keyboardAudio)?.effect, .conflict)
        XCTAssertEqual(conflicting.change(for: .luminanceAnchors)?.effect, .conflict)
        let kept = DisplaySettingsTransfer.applying(conflicting, selection: Set(DisplaySettingsTransfer.Category.allCases), to: settings)
        XCTAssertEqual(kept.keyboardAudioByDisplay[old.rawValue], settings.keyboardAudioByDisplay[old.rawValue])
        XCTAssertEqual(kept.keyboardAudioByDisplay[new.rawValue]?.nativeAudioEnabled, true)
        XCTAssertFalse(kept.showsVolumeFeedback(for: new))
        XCTAssertEqual(kept.luminanceAnchorsByDisplay, settings.luminanceAnchorsByDisplay)
        settings.keyboardAudioByDisplay[old.rawValue]?.nativeAudioDevice = "changed UID"
        let changed = try DisplaySettingsTransfer.migrationPlan(for: entry, liveID: new, settings: settings,
            favorites: favorites, menuLayout: menu)
        XCTAssertNotEqual(changed, conflicting, "changed values invalidate the confirmation, even when both remain conflicts")
    }

}
