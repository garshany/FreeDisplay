import XCTest
import DisplayDomain
@testable import TopologyCore

/// SD-09 / FB-13: the remembered-display inventory and what forgetting or resetting one removes —
/// and, just as important, what it keeps.
final class RememberedDisplayCleanupTests: XCTestCase {
    private let desk = DisplayRecordID.forCGUUID("DESK")
    private let deskOtherPort = DisplayRecordID.forCGUUID("DESK-2")
    private let laptop = DisplayRecordID.forCGUUID("LAPTOP")
    private let tv = DisplayRecordID.forCGUUID("TV")

    private func record(_ id: String, alias: String? = nil, model: String? = nil,
                        tags: Set<String> = []) -> DisplayRecord {
        DisplayRecord(id: .init(rawValue: id), alias: alias, tags: tags,
                      fingerprint: DisplayFingerprint(vendorID: 1, productID: 1, modelName: model),
                      displayClass: .external)
    }

    private func offline(_ id: DisplayRecordID, failed: Bool = false) -> ManagedOfflineDisplay {
        ManagedOfflineDisplay(recordID: id, cgID: 7, name: "Desk", displayClass: .external,
                              reconnectFailedAt: failed ? Date(timeIntervalSince1970: 1) : nil)
    }

    private func observation(_ id: DisplayRecordID, main: Bool = false) -> DisplayObservation {
        DisplayObservation(recordID: id, cgDisplayID: 1, isActive: true, isMain: main,
                           displayClass: .external, generation: .initial)
    }

    private func protectedLayout(_ ids: [DisplayRecordID]) -> ProtectedConfig {
        ProtectedConfig(snapshot: TopologySnapshot(generation: .init(1), observations: ids.map { observation($0) }),
                        capturedAt: Date(timeIntervalSince1970: 0))
    }

    private func mode(_ width: Int) -> DisplayMode {
        DisplayMode(pixelWidth: width, pixelHeight: 1080, pointWidth: width, pointHeight: 1080,
                    refreshHz: 60, isHiDPI: false)
    }

    /// A settings file in which `desk` (under both of its UUIDs) and `laptop` each have something of
    /// every kind the cleanup knows about.
    private func populatedSettings() -> OpenDisplaySettings {
        var settings = OpenDisplaySettings()
        settings.displayGroups = [
            DisplayGroup(name: "Desk pair", memberRecordIDs: [desk, laptop],
                         offsetByMember: [desk.rawValue: 0.1, laptop.rawValue: -0.1]),
            DisplayGroup(name: "Other", memberRecordIDs: [tv]),
        ]
        settings.protectedLayouts = [
            "with-desk": protectedLayout([desk, laptop]),
            "laptop-alone": protectedLayout([laptop]),
        ]
        settings.softwareBrightnessDisplayIDs = [desk.rawValue, laptop.rawValue]
        settings.ddcAppleDisplayOverrideIDs = [deskOtherPort.rawValue]
        settings.adaptiveBrightnessOffsetByDisplay = [desk.rawValue: 0.2, laptop.rawValue: 0.3]
        settings.faceLightPriorStateByDisplay = [desk.rawValue: .init(brightness: 0.4)]
        settings.adaptiveDayPresetByDisplay = [desk.rawValue: 5]
        settings.appPresetPriorStateByDisplay = [laptop.rawValue: .init(brightness: 0.5)]
        settings.hotkeyShortcuts.addInputSwitchBinding(
            InputSwitchBinding(displayID: deskOtherPort, inputCode: 0x11, binding: KeyBinding(keyCode: 1, modifiers: 2)))
        settings.appPresets = [
            .init(bundleIdentifier: "com.example.photo", applicationName: "Photo", brightness: 0.9,
                  target: .display(desk.rawValue)),
            .init(bundleIdentifier: "com.example.all", applicationName: "Everywhere", brightness: 0.2),
        ]
        return settings
    }

    private func populatedFavorites() -> FavoriteResolutions {
        var favorites = FavoriteResolutions()
        favorites.add(mode(1920), for: desk)
        favorites.add(mode(2560), for: deskOtherPort)
        favorites.add(mode(1440), for: laptop)
        return favorites
    }

    private func populatedLayout() -> MenuLayoutSettings {
        var layout = MenuLayoutSettings()
        layout.setHidden(true, for: [desk])
        layout.setIconSymbol("tv", for: [laptop])
        layout.displayOrder = [laptop.rawValue, desk.rawValue, deskOtherPort.rawValue]
        layout.setPlacement(.hidden, for: .volume)
        return layout
    }

    private func deskEntry(status: RememberedDisplay.Status,
                           ledger: ManagedOfflineDisplay? = nil) -> RememberedDisplay {
        RememberedDisplay(id: "disp_desk", record: record("disp_desk", alias: "Desk", tags: ["studio"]),
                          isRegistered: true, observationIDs: [desk, deskOtherPort],
                          status: status, offline: ledger)
    }

    // MARK: - Inventory

    func testInventoryMergesRegistryLiveAndLedgerIntoOneEntryEach() {
        let deskRecord = record("disp_desk", alias: "Desk")
        let laptopRecord = record("disp_laptop", model: "Built-in")
        let tvRecord = record("disp_tv", model: "TV")
        let entries = RememberedDisplayInventory.build(
            registry: [(deskRecord, [desk, deskOtherPort]), (laptopRecord, [laptop]), (tvRecord, [tv])],
            live: [.init(observationID: laptop, record: laptopRecord)],
            offline: [offline(desk)])
        XCTAssertEqual(entries.map(\.id), ["disp_laptop", "disp_desk", "disp_tv"])
        XCTAssertEqual(entries.map(\.status), [.connected, .turnedOff, .notConnected])
        XCTAssertEqual(entries[1].observationIDs, [desk, deskOtherPort])
        XCTAssertEqual(entries[1].offline?.recordID, desk)
        XCTAssertEqual(entries.map(\.cleanupMode), [.reset, .forget, .forget])
        XCTAssertEqual(entries.map(\.forgetRefusal), [.connected, .turnedOffByApp, nil])
    }

    func testInventoryShowsAFailedReconnectAheadOfOtherTurnedOffDisplays() {
        let entries = RememberedDisplayInventory.build(
            registry: [(record("disp_desk", alias: "A"), [desk]), (record("disp_tv", alias: "B"), [tv])],
            live: [], offline: [offline(desk), offline(tv, failed: true)])
        XCTAssertEqual(entries.map(\.status), [.reconnectFailed, .turnedOff])
        XCTAssertTrue(entries.allSatisfy(\.isTurnedOffByApp))
    }

    /// A ledger entry the registry has no record for is still a display OpenDisplay switched off —
    /// it must be listed, or its card could never be dismissed.
    func testInventoryListsALedgerEntryWithoutARecord() {
        let entries = RememberedDisplayInventory.build(registry: [], live: [], offline: [offline(tv, failed: true)])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].observationIDs, [tv])
        XCTAssertFalse(entries[0].isRegistered)
        XCTAssertEqual(entries[0].status, .reconnectFailed)
    }

    /// A provisional (ambiguous) live display is connected but has no persisted record to forget.
    func testInventoryListsAProvisionalLiveDisplayAsConnectedAndUnregistered() {
        let provisional = DisplayRecord(id: .init(rawValue: "unresolved:TV"), fingerprint: DisplayFingerprint(),
                                        unresolvedCandidates: [.init(rawValue: "disp_a")])
        let entries = RememberedDisplayInventory.build(
            registry: [], live: [.init(observationID: tv, record: provisional)], offline: [])
        XCTAssertEqual(entries.map(\.status), [.connected])
        XCTAssertFalse(entries[0].isRegistered)
        XCTAssertEqual(entries[0].cleanupMode, .reset)
    }

    /// A record a live provisional display couldn't be told apart from may be that very display:
    /// the entry says so (it stays "not connected" — nothing proves it is).
    func testInventoryFlagsARecordALiveAmbiguousDisplayMayBe() {
        let candidate = record("disp_a", alias: "Left")
        let provisional = DisplayRecord(id: .init(rawValue: "unresolved:TV"), fingerprint: DisplayFingerprint(),
                                        unresolvedCandidates: [candidate.id])
        let entries = RememberedDisplayInventory.build(
            registry: [(candidate, [desk]), (record("disp_b", alias: "Other"), [laptop])],
            live: [.init(observationID: tv, record: provisional)], offline: [])
        let flagged = entries.first { $0.id == "disp_a" }
        XCTAssertEqual(flagged?.status, .notConnected)
        XCTAssertEqual(flagged?.mayBeConnectedDisplay, true)
        XCTAssertEqual(entries.first { $0.id == "disp_b" }?.mayBeConnectedDisplay, false)
    }

    /// A display without a CG UUID has no index entry; its live resolution is what links it.
    func testInventoryLinksAUUIDLessLiveDisplayThroughItsResolvedRecord() {
        let bare = DisplayRecordID(rawValue: "cgid:5")
        let deskRecord = record("disp_desk")
        let entries = RememberedDisplayInventory.build(
            registry: [(deskRecord, [])], live: [.init(observationID: bare, record: deskRecord)], offline: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].observationIDs, [bare])
        XCTAssertEqual(entries[0].status, .connected)
    }

    // MARK: - Plan

    func testForgettingAConnectedDisplayIsRefused() {
        XCTAssertThrowsError(try RememberedDisplayCleanup.plan(
            for: deskEntry(status: .connected), mode: .forget, settings: populatedSettings(),
            favorites: populatedFavorites(), menuLayout: populatedLayout(), ledger: [])) { error in
            XCTAssertEqual(error as? RememberedDisplayCleanup.Refusal, .connected)
        }
    }

    func testForgetPlanListsEveryAffectedSettingAndKeepsPendingRestores() throws {
        let plan = try RememberedDisplayCleanup.plan(
            for: deskEntry(status: .notConnected), mode: .forget, settings: populatedSettings(),
            favorites: populatedFavorites(), menuLayout: populatedLayout(), ledger: [])
        XCTAssertEqual(plan.registryRecordID?.rawValue, "disp_desk")
        XCTAssertEqual(plan.alias, "Desk")
        XCTAssertEqual(plan.tagCount, 1)
        XCTAssertEqual(plan.favoriteModeCount, 2, "both of the display's UUIDs count")
        XCTAssertEqual(plan.groupNames, ["Desk pair"])
        XCTAssertEqual(plan.protectedLayoutKeys, ["with-desk"])
        XCTAssertTrue(plan.hasMenuPreferences)
        XCTAssertTrue(plan.softwareBrightness)
        XCTAssertTrue(plan.appleDDCOverride, "the override was set under the second UUID")
        XCTAssertTrue(plan.adaptiveOffset)
        XCTAssertFalse(plan.removesTurnedOffRecord)
        XCTAssertEqual(Set(plan.keptRestores), [.faceLight, .eveningColorPreset])
        // The user's own rules aimed at it are kept, and said to be.
        XCTAssertEqual(plan.keptInputSwitchHotkeys, 1)
        XCTAssertEqual(plan.keptAppPresetNames, ["Photo"])
        let after = RememberedDisplayCleanup.applying(plan, to: populatedSettings())
        XCTAssertEqual(after.hotkeyShortcuts.inputSwitchBindings.count, 1)
        XCTAssertEqual(after.appPresets.count, 2)
    }

    /// A display OpenDisplay switched off is still owed its way back: no forgetting until a
    /// reconnect has found no display — and never for the built-in panel, which the safety net
    /// relights from that same entry.
    func testForgettingADisplayStillOwedItsWayBackIsRefused() throws {
        let still = deskEntry(status: .turnedOff, ledger: offline(desk))
        XCTAssertThrowsError(try RememberedDisplayCleanup.plan(
            for: still, mode: .forget, settings: OpenDisplaySettings(), favorites: FavoriteResolutions(),
            menuLayout: MenuLayoutSettings(), ledger: [offline(desk)])) { error in
            XCTAssertEqual(error as? RememberedDisplayCleanup.Refusal, .turnedOffByApp)
        }

        var builtInOff = ManagedOfflineDisplay(recordID: laptop, cgID: 1, name: "Built-in", displayClass: .builtIn)
        builtInOff.reconnectFailedAt = Date(timeIntervalSince1970: 1)
        let builtIn = RememberedDisplay(id: "disp_laptop", record: record("disp_laptop"), isRegistered: true,
                                        observationIDs: [laptop], status: .reconnectFailed, offline: builtInOff)
        XCTAssertEqual(builtIn.forgetRefusal, .builtInTurnedOff)
        XCTAssertThrowsError(try RememberedDisplayCleanup.plan(
            for: builtIn, mode: .forget, settings: OpenDisplaySettings(), favorites: FavoriteResolutions(),
            menuLayout: MenuLayoutSettings(), ledger: [builtInOff]))

        // An external whose reconnect found nothing — unplugged while off — can be forgotten.
        XCTAssertNil(deskEntry(status: .reconnectFailed, ledger: offline(desk, failed: true)).forgetRefusal)
    }

    func testForgetRemovesTheDisplaysDataAndLeavesOtherDisplaysAndRestoreLedgersAlone() throws {
        let settings = populatedSettings()
        let plan = try RememberedDisplayCleanup.plan(
            for: deskEntry(status: .notConnected), mode: .forget, settings: settings,
            favorites: populatedFavorites(), menuLayout: populatedLayout(), ledger: [])

        let after = RememberedDisplayCleanup.applying(plan, to: settings)
        XCTAssertEqual(after.displayGroups.map(\.memberRecordIDs), [[laptop], [tv]])
        XCTAssertNil(after.displayGroups[0].offsetByMember[desk.rawValue], "the learned offset goes with the member")
        XCTAssertEqual(after.displayGroups[0].offsetByMember[laptop.rawValue], -0.1)
        XCTAssertEqual(Set(after.protectedLayouts.keys), ["laptop-alone"])
        XCTAssertEqual(after.softwareBrightnessDisplayIDs, [laptop.rawValue])
        XCTAssertTrue(after.ddcAppleDisplayOverrideIDs.isEmpty)
        XCTAssertEqual(after.adaptiveBrightnessOffsetByDisplay, [laptop.rawValue: 0.3])
        // Owed restores survive: they put the monitor's own values back when it returns.
        XCTAssertEqual(after.faceLightPriorStateByDisplay, settings.faceLightPriorStateByDisplay)
        XCTAssertEqual(after.adaptiveDayPresetByDisplay, settings.adaptiveDayPresetByDisplay)
        XCTAssertEqual(after.appPresetPriorStateByDisplay, settings.appPresetPriorStateByDisplay)

        let favorites = RememberedDisplayCleanup.applying(plan, to: populatedFavorites())
        XCTAssertTrue(favorites.favoriteKeys(for: desk).isEmpty)
        XCTAssertTrue(favorites.favoriteKeys(for: deskOtherPort).isEmpty)
        XCTAssertEqual(favorites.favoriteKeys(for: laptop).count, 1)

        let layout = RememberedDisplayCleanup.applying(plan, to: populatedLayout())
        XCTAssertFalse(layout.isHidden(desk))
        XCTAssertEqual(layout.displayOrder, [laptop.rawValue])
        XCTAssertEqual(layout.iconSymbol(for: laptop), "tv")
        XCTAssertEqual(layout.placement(of: .volume), .hidden, "menu contents are not a display's data")
    }

    func testForgettingATurnedOffDisplayRemovesItsRecoveryRecordAndSaysSo() throws {
        let ledger = [offline(desk, failed: true), offline(tv)]
        let plan = try RememberedDisplayCleanup.plan(
            for: deskEntry(status: .reconnectFailed, ledger: ledger[0]), mode: .forget,
            settings: OpenDisplaySettings(), favorites: FavoriteResolutions(),
            menuLayout: MenuLayoutSettings(), ledger: ledger)
        XCTAssertTrue(plan.removesTurnedOffRecord)
        XCTAssertEqual(RememberedDisplayCleanup.applying(plan, to: ledger).map(\.recordID), [tv])
    }

    /// Resetting a connected display keeps what lets OpenDisplay recognize it — and its ledger entry,
    /// which can still owe an "off" after a wake relit it.
    func testResetKeepsTheLedgerAndClearsTheSameSettingsAsForget() throws {
        let ledger = [offline(desk)]
        let settings = populatedSettings()
        let plan = try RememberedDisplayCleanup.plan(
            for: deskEntry(status: .connected, ledger: ledger[0]), mode: .reset, settings: settings,
            favorites: populatedFavorites(), menuLayout: populatedLayout(), ledger: ledger)
        XCTAssertEqual(plan.mode, .reset)
        XCTAssertFalse(plan.removesTurnedOffRecord)
        XCTAssertEqual(RememberedDisplayCleanup.applying(plan, to: ledger), ledger)
        let after = RememberedDisplayCleanup.applying(plan, to: settings)
        XCTAssertEqual(Set(after.protectedLayouts.keys), ["laptop-alone"])
        XCTAssertEqual(after.faceLightPriorStateByDisplay, settings.faceLightPriorStateByDisplay)
    }

    func testPlanForADisplayWithNothingSavedRemovesOnlyTheRecord() throws {
        let entry = RememberedDisplay(id: "disp_tv", record: record("disp_tv"), isRegistered: true,
                                      observationIDs: [tv], status: .notConnected, offline: nil)
        let plan = try RememberedDisplayCleanup.plan(
            for: entry, mode: .forget, settings: populatedSettings(), favorites: populatedFavorites(),
            menuLayout: populatedLayout(), ledger: [])
        // `tv` is in a group, so that is the one association it has.
        XCTAssertEqual(plan.groupNames, ["Other"])
        let bare = try RememberedDisplayCleanup.plan(
            for: entry, mode: .forget, settings: OpenDisplaySettings(), favorites: FavoriteResolutions(),
            menuLayout: MenuLayoutSettings(), ledger: [])
        XCTAssertTrue(bare.removesOnlyRecord)
        XCTAssertTrue(bare.keptRestores.isEmpty)
    }

    /// A provisional record isn't persisted, so the plan has no registry record to remove.
    func testPlanForAnUnregisteredEntryHasNoRegistryRecord() throws {
        let entry = RememberedDisplay(id: tv.rawValue, record: nil, isRegistered: false,
                                      observationIDs: [tv], status: .reconnectFailed, offline: offline(tv, failed: true))
        let plan = try RememberedDisplayCleanup.plan(
            for: entry, mode: .forget, settings: OpenDisplaySettings(), favorites: FavoriteResolutions(),
            menuLayout: MenuLayoutSettings(), ledger: [offline(tv, failed: true)])
        XCTAssertNil(plan.registryRecordID)
        XCTAssertTrue(plan.removesTurnedOffRecord)
    }

    // MARK: - Registry

    func testRegistryForgetRemovesTheRecordAndItsUUIDRoutes() async {
        let registry = await DisplayRegistry(store: InMemoryRegistryStore())
        let fingerprint = DisplayFingerprint(vendorID: 1, productID: 2, serialNumber: "S1")
        let first = await registry.resolve(fingerprint: fingerprint, cgUUID: "U1")
        _ = await registry.resolve(fingerprint: fingerprint, cgUUID: "U2")  // same display, other port
        let other = await registry.resolve(fingerprint: DisplayFingerprint(vendorID: 9, productID: 9, serialNumber: "Z"),
                                           cgUUID: "U3")
        let listed = await registry.rememberedDisplays()
        XCTAssertEqual(listed.first { $0.record.id == first.id }?.observationIDs,
                       [.forCGUUID("U1"), .forCGUUID("U2")])

        let removed = await registry.forget(first.id)
        XCTAssertTrue(removed)
        let remaining = await registry.allRecords().map(\.id)
        XCTAssertEqual(remaining, [other.id])
        let routed = await registry.record(forCGUUID: "U1")
        XCTAssertNil(routed)
        let kept = await registry.record(forCGUUID: "U3")
        XCTAssertEqual(kept?.id, other.id)
        let again = await registry.forget(first.id)
        XCTAssertFalse(again)

        // Seen again, the display is a new record rather than the forgotten one coming back.
        let rediscovered = await registry.resolve(fingerprint: fingerprint, cgUUID: "U1")
        XCTAssertNotEqual(rediscovered.id, first.id)
        XCTAssertNil(rediscovered.alias)
    }

    func testRegistryClearUserDataKeepsIdentityAndRouting() async {
        let registry = await DisplayRegistry(store: InMemoryRegistryStore())
        let fingerprint = DisplayFingerprint(vendorID: 1, productID: 2, serialNumber: "S1")
        let record = await registry.resolve(fingerprint: fingerprint, cgUUID: "U1")
        await registry.setAlias("Desk", for: record.id)
        await registry.addTag("studio", to: record.id)
        await registry.confirmPairing(for: record.id)

        await registry.clearUserData(for: record.id)
        let cleared = await registry.record(for: record.id)
        XCTAssertNil(cleared?.alias)
        XCTAssertEqual(cleared?.tags, [])
        XCTAssertEqual(cleared?.pairingConfirmed, true, "identity evidence is not a preference")
        let again = await registry.resolve(fingerprint: fingerprint, cgUUID: "U1")
        XCTAssertEqual(again.id, record.id, "still recognized as itself")
    }

    func testFavoritesRemoveAllDropsOnlyThatDisplay() {
        var favorites = populatedFavorites()
        favorites.removeAll(for: desk)
        XCTAssertTrue(favorites.favoriteKeys(for: desk).isEmpty)
        XCTAssertEqual(favorites.favoriteKeys(for: deskOtherPort).count, 1)
    }
}
