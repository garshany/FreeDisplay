import XCTest
import DisplayDomain
import SceneEngine
@testable import TopologyCore

final class SettingsArchiveTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("od-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private let desk = DisplayRecordID.forCGUUID("DESK-UUID")
    private let travel = DisplayRecordID.forCGUUID("TRAVEL-UUID")

    /// Settings touching every kind of field: plain preferences, display-keyed preferences, and
    /// all three restore ledgers.
    private func richSettings() -> OpenDisplaySettings {
        var shortcuts = KeyboardShortcutRegistry.defaults
        shortcuts.addInputSwitchBinding(InputSwitchBinding(
            id: "hdmi", displayID: travel, inputCode: 0x11, binding: KeyBinding(keyCode: 18, modifiers: 256)))
        return OpenDisplaySettings(
            persistencePolicy: .reconnectOnWake,
            confirmationCountdownSeconds: 9,
            hotkeyShortcuts: shortcuts,
            displayNotificationsEnabled: true,
            osdStyle: .minimal,
            faceLightPriorStateByDisplay: [desk.rawValue: FaceLightPolicy.PriorState(brightness: 0.4)],
            adaptiveBrightnessSyncEnabled: true,
            adaptiveDayPresetByDisplay: [desk.rawValue: 5],
            adaptiveBrightnessOffsetByDisplay: [desk.rawValue: 0.1],
            softwareBrightnessDisplayIDs: [desk.rawValue],
            appPresetsEnabled: true,
            appPresets: [AppPresetPolicy.AppPreset(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, bundleIdentifier: "com.figma.Desktop", applicationName: "Figma",
                brightness: 0.6, target: .display(travel.rawValue))],
            appPresetPriorStateByDisplay: [travel.rawValue: AppPresetPolicy.PriorState(brightness: 0.9)],
            layoutProtectionEnabled: true,
            displayGroups: [DisplayGroup(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
                                         name: "Desk", memberRecordIDs: [desk, travel])],
            notificationStyle: .appWindow,
            routineProtectionNoticesEnabled: false,
            dockIconPolicy: .always)
    }

    private func registry() -> RegistryState {
        let record = DisplayRecord(
            id: DisplayRecordID(rawValue: "disp_1"), alias: "Desk",
            fingerprint: DisplayFingerprint(vendorID: 4268, productID: 41_200, modelName: "U2720Q"),
            displayClass: .external, lastSeen: now)
        return RegistryState(records: [record], cgUUIDIndex: ["DESK-UUID": record.id])
    }

    private func archive(settings: OpenDisplaySettings? = nil) -> SettingsArchive {
        var favorites = FavoriteResolutions()
        favorites.toggle(DisplayMode(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080,
                                     refreshHz: 60, isHiDPI: true), for: desk)
        let scene = Scene(id: "scene_1", name: "Docked",
                          members: [Scene.Member(selector: "id:\(desk.rawValue)", required: true,
                                                 desired: DesiredState())])
        return SettingsArchive(createdAt: now, appVersion: "0.11.5 (24)", settings: settings ?? richSettings(),
                               favorites: favorites, registry: registry(), scenes: [scene],
                               defaults: ArchivedDefaults(experimentalRotationEnabled: true))
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// A valid archive as a mutable JSON object, for tests that damage one part of it.
    private func archiveObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: archive().encoded()) as? [String: Any])
    }

    // MARK: - Round trip

    func testRoundTripPreservesEverySection() throws {
        let original = archive()
        let decoded = try SettingsArchive.decode(original.encoded())
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.version, SettingsArchive.currentVersion)
        XCTAssertEqual(decoded.settings.notificationStyle, .appWindow)
        XCTAssertEqual(decoded.settings.dockIconPolicy, .always)
        XCTAssertEqual(decoded.settings.displayGroups.first?.memberRecordIDs, [desk, travel])
        XCTAssertEqual(decoded.registry.records.first?.alias, "Desk")
        XCTAssertEqual(decoded.scenes.map(\.name), ["Docked"])
        XCTAssertTrue(decoded.defaults.experimentalRotationEnabled)
        XCTAssertEqual(decoded.appVersion, "0.11.5 (24)")
    }

    func testRoundTripThroughAFile() throws {
        let url = directory.appendingPathComponent("export.json")
        try archive().write(to: url)
        XCTAssertEqual(try SettingsArchive.read(from: url), archive())
    }

    func testArchiveNeverCarriesRestoreLedgers() throws {
        let made = archive()
        XCTAssertTrue(made.settings.faceLightPriorStateByDisplay.isEmpty)
        XCTAssertTrue(made.settings.adaptiveDayPresetByDisplay.isEmpty)
        XCTAssertTrue(made.settings.appPresetPriorStateByDisplay.isEmpty)
        // The preferences next to the ledgers are kept.
        XCTAssertEqual(made.settings.adaptiveBrightnessOffsetByDisplay, [desk.rawValue: 0.1])
        XCTAssertEqual(made.settings.appPresets.count, 1)
    }

    func testHandEditedLedgerIsStrippedOnDecode() throws {
        var object = try archiveObject()
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings["adaptiveDayPresetByDisplay"] = [desk.rawValue: 4]
        object["settings"] = settings
        let decoded = try SettingsArchive.decode(json(object))
        XCTAssertTrue(decoded.settings.adaptiveDayPresetByDisplay.isEmpty)
    }

    func testMissingDefaultsSectionFallsBackToDefaults() throws {
        var object = try archiveObject()
        object["defaults"] = nil
        let decoded = try SettingsArchive.decode(json(object))
        XCTAssertEqual(decoded.defaults, ArchivedDefaults())
    }

    func testSettingsSectionKeepsPerKeyTolerance() throws {
        // A field a different build wrote in a shape this one doesn't know costs that field only.
        var object = try archiveObject()
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings["dockIconPolicy"] = "fromTheFuture"
        settings["futureKey"] = 42
        object["settings"] = settings
        let decoded = try SettingsArchive.decode(json(object))
        XCTAssertEqual(decoded.settings.dockIconPolicy, OpenDisplaySettings.default.dockIconPolicy)
        XCTAssertEqual(decoded.settings.confirmationCountdownSeconds, 9)
    }

    // MARK: - Version check

    func testNewerVersionIsRefused() throws {
        var object = try archiveObject()
        object["version"] = SettingsArchive.currentVersion + 1
        XCTAssertThrowsError(try SettingsArchive.decode(json(object))) { error in
            XCTAssertEqual(error as? SettingsArchiveError, .newerVersion(SettingsArchive.currentVersion + 1))
        }
    }

    func testVersionZeroIsRefused() throws {
        var object = try archiveObject()
        object["version"] = 0
        XCTAssertThrowsError(try SettingsArchive.decode(json(object))) { error in
            XCTAssertEqual(error as? SettingsArchiveError, .unsupportedVersion(0))
        }
    }

    func testMissingVersionIsDamage() throws {
        var object = try archiveObject()
        object["version"] = nil
        XCTAssertThrowsError(try SettingsArchive.decode(json(object))) { error in
            XCTAssertEqual(error as? SettingsArchiveError, .damaged(section: "version"))
        }
    }

    // MARK: - Invalid files

    func testNonJSONIsNotAnArchive() {
        XCTAssertThrowsError(try SettingsArchive.decode(Data("not json at all".utf8))) { error in
            XCTAssertEqual(error as? SettingsArchiveError, .notAnArchive)
        }
        XCTAssertThrowsError(try SettingsArchive.decode(Data("[1, 2, 3]".utf8))) { error in
            XCTAssertEqual(error as? SettingsArchiveError, .notAnArchive)
        }
    }

    func testPlainSettingsFileIsNotAnArchive() throws {
        // settings.json itself is valid JSON with settings in it, but no marker: refusing it keeps
        // a random JSON file from being "imported" as all-defaults.
        let encoder = JSONEncoder()
        let data = try encoder.encode(richSettings())
        XCTAssertThrowsError(try SettingsArchive.decode(data)) { error in
            XCTAssertEqual(error as? SettingsArchiveError, .notAnArchive)
        }
    }

    func testForeignFormatMarkerIsNotAnArchive() throws {
        var object = try archiveObject()
        object["format"] = "com.example.other-app"
        XCTAssertThrowsError(try SettingsArchive.decode(json(object))) { error in
            XCTAssertEqual(error as? SettingsArchiveError, .notAnArchive)
        }
    }

    func testDamagedSectionIsNamed() throws {
        for section in ["settings", "favorites", "registry", "scenes", "createdAt"] {
            var object = try archiveObject()
            object[section] = "garbage"
            XCTAssertThrowsError(try SettingsArchive.decode(json(object)), section) { error in
                XCTAssertEqual(error as? SettingsArchiveError, .damaged(section: section))
            }
        }
        var missing = try archiveObject()
        missing["registry"] = nil
        XCTAssertThrowsError(try SettingsArchive.decode(json(missing))) { error in
            XCTAssertEqual(error as? SettingsArchiveError, .damaged(section: "registry"))
        }
    }

    func testMissingFileIsUnreadable() {
        let url = directory.appendingPathComponent("absent.json")
        XCTAssertThrowsError(try SettingsArchive.read(from: url)) { error in
            XCTAssertEqual(error as? SettingsArchiveError, .unreadable)
        }
    }

    // MARK: - Backups and replacement

    func testBackupIsWrittenAndRestorable() throws {
        let store = SettingsBackupStore(directory: directory.appendingPathComponent("settings-backups"))
        let url = try store.backUp(archive(), now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "settings-backups")
        XCTAssertEqual(try SettingsArchive.read(from: url), archive())
    }

    func testBackupsNeverOverwriteEachOther() throws {
        let store = SettingsBackupStore(directory: directory)
        let first = try store.backUp(archive(), now: now)
        let second = try store.backUp(SettingsArchive.factoryDefaults(createdAt: now, appVersion: nil), now: now)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try SettingsArchive.read(from: first), archive())
        XCTAssertEqual(try SettingsArchive.read(from: second).settings, .default)
    }

    func testReplacementBacksUpCurrentStateAndCarriesLiveLedgers() throws {
        let store = SettingsBackupStore(directory: directory)
        let live = richSettings()
        let current = archive(settings: live)
        let incoming = SettingsArchive.factoryDefaults(createdAt: now, appVersion: nil)

        let replacement = try store.prepareReplacement(current: current, live: live, incoming: incoming, now: now)

        XCTAssertEqual(try SettingsArchive.read(from: replacement.backupURL), current)
        // Preferences come from the incoming archive…
        XCTAssertEqual(replacement.archive.settings.withoutRestoreLedgers(), OpenDisplaySettings.default)
        XCTAssertTrue(replacement.archive.registry.records.isEmpty)
        // …but a display FaceLight or a preset holds right now is still owed its values back.
        XCTAssertEqual(replacement.archive.settings.faceLightPriorStateByDisplay, live.faceLightPriorStateByDisplay)
        XCTAssertEqual(replacement.archive.settings.adaptiveDayPresetByDisplay, live.adaptiveDayPresetByDisplay)
        XCTAssertEqual(replacement.archive.settings.appPresetPriorStateByDisplay, live.appPresetPriorStateByDisplay)
    }

    func testReplacementProducesNothingWhenTheBackupCannotBeWritten() throws {
        // The backup folder's path runs through a regular file, so it can never be created.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let store = SettingsBackupStore(directory: blocker.appendingPathComponent("settings-backups"))
        XCTAssertThrowsError(try store.prepareReplacement(
            current: archive(), live: richSettings(),
            incoming: SettingsArchive.factoryDefaults(createdAt: now, appVersion: nil), now: now))
    }

    // MARK: - Display identity

    func testReferencedDisplaysCoverEveryDisplayKeyedPreference() {
        let ids = archive().referencedDisplayIDs
        // desk: software brightness, offset, group, favourites; travel: app preset, group, input switch.
        XCTAssertEqual(ids, [desk, travel])
    }

    func testReferencedDisplaysIncludeProtectedLayoutsAndAppleOverrides() {
        let docked = DisplayRecordID.forCGUUID("DOCKED-UUID")
        let apple = DisplayRecordID.forCGUUID("APPLE-UUID")
        let observation = DisplayObservation(
            recordID: docked, cgDisplayID: 2, isActive: true, origin: .init(x: 0, y: 0),
            mode: nil, rotation: .degrees0, isMain: true, mirrorSourceID: nil,
            displayClass: .external, generation: .initial)
        var settings = OpenDisplaySettings.default
        settings.ddcAppleDisplayOverrideIDs = [apple.rawValue]
        settings.protectedLayouts = ["set": ProtectedConfig(
            snapshot: TopologySnapshot(generation: .init(1), observations: [observation]), capturedAt: now)]
        let archive = SettingsArchive(createdAt: now, appVersion: nil, settings: settings,
                                      favorites: FavoriteResolutions(), registry: RegistryState(), scenes: [],
                                      defaults: ArchivedDefaults())
        XCTAssertEqual(archive.referencedDisplayIDs, [docked, apple])
    }

    func testUnmatchedDisplaysAreTheReferencesThisMacDoesNotKnow() {
        let unmatched = archive().unmatchedDisplays(known: [desk])
        XCTAssertEqual(unmatched.map(\.id), [travel])
        XCTAssertNil(unmatched.first?.name, "the archive's registry has no record for it")

        let named = archive().unmatchedDisplays(known: [])
        XCTAssertEqual(named.first { $0.id == desk }?.name, "Desk", "named through the archived UUID index")
        XCTAssertTrue(archive().unmatchedDisplays(known: [desk, travel]).isEmpty)
    }

    // MARK: - Installing an archive into the live stores

    func testRegistryReplaceStateReplacesMemoryAndStore() async {
        let store = InMemoryRegistryStore()
        let live = await DisplayRegistry(store: store)
        _ = await live.resolve(fingerprint: DisplayFingerprint(vendorID: 1, productID: 2, serialNumber: "OLD"),
                               cgUUID: "OLD-UUID")
        let imported = registry()

        await live.replaceState(imported)

        let current = await live.currentState()
        let persisted = await store.load()
        XCTAssertEqual(current, imported)
        XCTAssertEqual(persisted, imported)
        // The imported record is what recognition now works from.
        let recognized = await live.record(forCGUUID: "DESK-UUID")
        XCTAssertEqual(recognized?.alias, "Desk")
        let forgotten = await live.record(forCGUUID: "OLD-UUID")
        XCTAssertNil(forgotten)
    }

    func testSceneLibraryReplaceAllReplacesMemoryAndStore() async {
        let store = InMemorySceneStore([Scene(id: "old", name: "Old", members: [])])
        let library = await SceneLibrary(store: store)
        let replacement = [Scene(id: "new", name: "New", members: [])]

        await library.replaceAll(with: replacement)

        let all = await library.all()
        let persisted = await store.load()
        XCTAssertEqual(all, replacement)
        XCTAssertEqual(persisted, replacement)
    }

    func testFactoryDefaultsAreFirstRunState() {
        let defaults = SettingsArchive.factoryDefaults(createdAt: now, appVersion: "1")
        XCTAssertEqual(defaults.settings, .default)
        XCTAssertTrue(defaults.registry.records.isEmpty)
        XCTAssertTrue(defaults.scenes.isEmpty)
        XCTAssertTrue(defaults.referencedDisplayIDs.isEmpty)
        XCTAssertEqual(defaults.defaults, ArchivedDefaults())
    }
}
