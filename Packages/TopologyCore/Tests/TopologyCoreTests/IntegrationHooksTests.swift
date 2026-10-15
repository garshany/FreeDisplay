import XCTest
@testable import TopologyCore
import AutomationSchema
import DisplayDomain

final class IntegrationHooksTests: XCTestCase {
    private let a = DisplayRecordID(rawValue: "desk-a"), b = DisplayRecordID(rawValue: "desk-b")
    func testFirstDiscoveryAndRepeatedConfigurationAreNotReconnects() {
        var state = IntegrationHookState()
        XCTAssertTrue(state.topology(connected: [a], remembered: [], ready: [a]).isEmpty)
        XCTAssertTrue(state.topology(connected: [a, b], remembered: [], ready: [a, b]).isEmpty)
        XCTAssertTrue(state.topology(connected: [a, b], remembered: [], ready: [a, b]).isEmpty)
    }
    func testRememberedReturnTargetsOnlyThatDisplayAndWaitsForReadiness() {
        var state = IntegrationHookState()
        _ = state.topology(connected: [a], remembered: [b], ready: [a])
        XCTAssertTrue(state.topology(connected: [a, b], remembered: [b], ready: [a]).isEmpty)
        let events = state.topology(connected: [a, b], remembered: [b], ready: [a, b])
        XCTAssertEqual(events.map(\.display), [b]); XCTAssertEqual(events.map(\.phase), [.hardReconnect])
        XCTAssertTrue(state.topology(connected: [a, b], remembered: [b], ready: [a, b]).isEmpty)
    }
    func testDisconnectAndReturnProduceOneEdgeEach() {
        var state = IntegrationHookState()
        _ = state.topology(connected: [a, b], remembered: [], ready: [a, b])
        XCTAssertEqual(state.topology(connected: [a], remembered: [b], ready: [a]).map(\.phase), [.hardDisconnect])
        XCTAssertTrue(state.topology(connected: [a], remembered: [b], ready: [a]).isEmpty)
        XCTAssertEqual(state.topology(connected: [a, b], remembered: [], ready: [a, b]).map(\.phase), [.hardReconnect])
    }
    func testSimultaneousReturnsHaveSeparateExplicitTargets() {
        var state = IntegrationHookState()
        _ = state.topology(connected: [], remembered: [a, b], ready: [])
        let events = state.topology(connected: [a, b], remembered: [], ready: [a, b])
        XCTAssertEqual(events.map(\.display), [a, b]); XCTAssertEqual(Set(events.map(\.transition)).count, 2)
    }
    func testFailedSoftDisconnectDoesNotInventHardLoss() {
        var state = IntegrationHookState()
        _ = state.topology(connected: [a], remembered: [], ready: [a])
        let attempt = UUID()
        XCTAssertEqual(state.soft(.softDisconnect, display: a, attempt: attempt).map(\.phase), [.softDisconnect])
        XCTAssertTrue(state.soft(.softDisconnect, display: a, attempt: attempt).isEmpty)
        XCTAssertTrue(state.topology(connected: [a], remembered: [], ready: [a]).isEmpty)
        XCTAssertEqual(state.topology(connected: [], remembered: [a], ready: []).map(\.phase), [.hardDisconnect])
    }
    func testSleepWakeOrderAndDeduplication() {
        var state = IntegrationHookState()
        _ = state.topology(connected: [a], remembered: [b], ready: [a])
        XCTAssertTrue(state.wake().isEmpty)
        XCTAssertEqual(state.sleep().map(\.phase), [.systemSleep]); XCTAssertTrue(state.sleep().isEmpty)
        XCTAssertEqual(state.wake().map(\.phase), [.systemWakeImmediate]); XCTAssertTrue(state.wake().isEmpty)
        let generation = state.wakeGeneration
        XCTAssertEqual(state.delayedWake(display: a, generation: generation)?.phase, .systemWake)
        XCTAssertNil(state.delayedWake(display: a, generation: generation))
        XCTAssertNil(state.delayedWake(display: b, generation: generation))
    }
    func testNewSleepInvalidatesDelayedWakeAndDisconnectedTargets() {
        var state = IntegrationHookState()
        _ = state.topology(connected: [a], remembered: [], ready: [a])
        _ = state.sleep(); _ = state.wake(); let old = state.wakeGeneration
        _ = state.sleep(); XCTAssertNil(state.delayedWake(display: a, generation: old))
        _ = state.wake(); let current = state.wakeGeneration
        _ = state.topology(connected: [], remembered: [a], ready: [])
        XCTAssertNil(state.delayedWake(display: a, generation: current))
    }
    func testNewConfigurationsAreInactiveAndImportRequiresReview() throws {
        let hook = IntegrationHook(phase: .hardReconnect)
        XCTAssertFalse(hook.enabled); XCTAssertEqual(hook.action, .none)
        let control = IntegrationControl(name: "Brightness", kind: .ranged(multiplier: 100, decimalPlaces: 0))
        XCTAssertFalse(control.enabled); XCTAssertNil(control.pollingSeconds)
        var display = DisplayIntegration(id: a, enabled: true, controls: [control], hooks: [hook])
        display.hooks[0].enabled = true; display.controls[0].enabled = true
        let config = IntegrationConfiguration(displays: [display])
        let paused = config.pausedForImport()
        XCTAssertFalse(paused.displays[0].enabled); XCTAssertFalse(paused.displays[0].hooks[0].enabled)
        XCTAssertFalse(paused.displays[0].controls[0].enabled)
        XCTAssertEqual(paused.displays[0].hooks[0].id, hook.id)
        XCTAssertEqual(try JSONDecoder().decode(IntegrationConfiguration.self, from: JSONEncoder().encode(config)), config)
    }
    func testInvalidIntervalsDuplicatePhasesAndUnknownParametersRefuseBeforeSave() {
        let duplicate = DisplayIntegration(id: a, hooks: [.init(phase: .hardReconnect), .init(phase: .hardReconnect)])
        XCTAssertThrowsError(try IntegrationConfiguration(displays: [duplicate]).validateForStorage())
        let invalid = IntegrationControl(name: "b", kind: .boolean, pollingSeconds: 0)
        XCTAssertThrowsError(try IntegrationConfiguration(displays: [.init(id: a, controls: [invalid])]).validateForStorage())
        XCTAssertThrowsError(try IntegrationConfiguration(displays: [.init(id: a, parameters: [.init("VALUE", "x")])]).validateForStorage())
    }
    func testSharedCatalogKeepsRememberedIdentityAfterUnpluggingAndReconnectsOnce() throws {
        let record = DisplayRecord(id: .init(rawValue: "registry-desk"), alias: "Desk", fingerprint: DisplayFingerprint())
        let known = [a: record]
        func catalog(_ connected: Bool) -> AutomationDisplaySet {
            AutomationDisplayCatalog.displaySet(displays: connected ? [DisplayObservation(recordID: a, isActive: true, generation: .initial)] : [],
                offline: [], name: { _ in "Desk" }, record: { known[$0] }, groups: [], pointerDisplayID: nil, generation: 0, remembered: known)
        }
        let absent = catalog(false)
        XCTAssertEqual(absent.candidates.count, 1)
        XCTAssertEqual(absent.candidates[0].availability, .disconnected)
        XCTAssertNil(absent.candidates[0].cgDisplayID)
        XCTAssertEqual(try AutomationSelectorResolver.resolveOne(.display(.id(record.id)), in: absent).id, a)
        let present = catalog(true)
        XCTAssertEqual(present.candidates.count, 1)
        var state = IntegrationHookState()
        _ = state.topology(connected: [], remembered: [a], ready: [])
        XCTAssertEqual(state.topology(connected: [a], remembered: [], ready: [a]).map(\.display), [a])
        XCTAssertTrue(state.topology(connected: [a], remembered: [], ready: [a]).isEmpty)
    }
    func testStorePreservesDefinitionsAndMissingFileMeansNoActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IntegrationConfigurationStore(directory: directory)
        XCTAssertTrue(try store.load().displays.isEmpty)
        let config = IntegrationConfiguration(displays: [.init(id: a, hooks: [.init(phase: .hardReconnect)])])
        try store.save(config); XCTAssertEqual(try store.load(), config)
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "broken")
    }
    func testArchiveReplacementPausesIncomingActionsAndBackupRetainsOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsBackupStore(directory: directory)
        var current = SettingsArchive.factoryDefaults(createdAt: Date(timeIntervalSince1970: 0), appVersion: "test")
        current.integrations = .init(displays: [.init(id: a, enabled: true, hooks: [.init(phase: .hardReconnect, enabled: true)])])
        let replacement = try store.prepareReplacement(current: current, live: .default, incoming: current)
        XCTAssertFalse(replacement.archive.integrations.displays[0].enabled)
        XCTAssertFalse(replacement.archive.integrations.displays[0].hooks[0].enabled)
        XCTAssertTrue(try SettingsArchive.read(from: replacement.backupURL).integrations.displays[0].enabled)
    }
    func testArchiveOldFormatMissingIntegrationKeyLoadsAndNewKeyRoundTrips() throws {
        var archive = SettingsArchive.factoryDefaults(createdAt: Date(timeIntervalSince1970: 0), appVersion: "test")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: archive.encoded()) as? [String: Any])
        object.removeValue(forKey: "integrations")
        XCTAssertTrue(try SettingsArchive.decode(JSONSerialization.data(withJSONObject: object)).integrations.displays.isEmpty)
        archive.integrations = .init(displays: [.init(id: a, enabled: true, hooks: [.init(phase: .hardReconnect, enabled: true)])])
        XCTAssertEqual(try SettingsArchive.decode(archive.encoded()).integrations, archive.integrations)
        XCTAssertTrue(archive.referencedDisplayIDs.contains(a))
    }
}
