import XCTest
import DisplayDomain
import AutomationSchema
@testable import TopologyCore

final class PersistentDisplayIdentityTests: XCTestCase {
    private let numeric = DisplayRecordID(rawValue: "cgid:42")

    func testNumericPreferencesAreQuarantinedLosslesslyAcrossLoadImportAndSave() throws {
        var settings = OpenDisplaySettings()
        let audio = DisplayKeyboardAudioPreferences(nativeAudioEnabled: true, nativeAudioDevice: "USB-A")
        let anchors = LuminanceAnchorSettings(manualValuesEnabled: false)
        settings.keyboardAudioByDisplay[numeric.rawValue] = audio
        settings.luminanceAnchorsByDisplay[numeric.rawValue] = anchors
        settings.preventDisplaySleepDisplayIDs.insert(numeric.rawValue)
        settings.clockMode = .init(timeZoneIdentifier: nil, resumePolicy: .currentInterval, displays: [schedule(numeric)])
        let loaded = try JSONDecoder().decode(OpenDisplaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.quarantinedDisplayIDs, [numeric])
        XCTAssertEqual(loaded.keyboardAudioPreferences(for: numeric), .default)
        XCTAssertNil(loaded.savedLuminanceAnchors(for: numeric))
        XCTAssertFalse(loaded.preventsDisplaySleep(for: numeric))
        var edited = loaded
        edited.setKeyboardAudioPreferences(.init(nativeAudioDevice: "B"), for: numeric)
        edited.setLuminanceAnchors(nil, for: numeric)
        edited.setPreventsDisplaySleep(false, for: numeric)
        XCTAssertEqual(edited, loaded, "a replacement receiving number 42 cannot edit A's quarantined preferences")
        let archive = SettingsArchive(createdAt: Date(), appVersion: nil, settings: loaded,
            favorites: .init(), registry: .init(), scenes: [], defaults: .init())
        XCTAssertEqual(archive.unmatchedDisplays(known: [numeric]).map(\.id), [numeric])
        let restored = try SettingsArchive.read(from: writeArchive(archive))
        XCTAssertEqual(restored.settings, loaded)
    }

    private func writeArchive(_ archive: SettingsArchive) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.json")
        try archive.write(to: url)
        return url
    }

    private func schedule(_ id: DisplayRecordID) -> ClockDisplaySchedule {
        .init(displayID: id, entries: [], method: .automatic,
              restoreLevel: AutomationLevel(normalized: 0.5)!, rampMinutes: 0)
    }

    func testNumericClockIntegrationAndKeepAwakeAssociationsNeverApplyToReusedNumber() {
        let clock = ClockModeSession().decision(schedule: schedule(numeric),
            sample: .init(level: .minimum, intervalStart: Date()), enabled: true,
            safeStartup: false, sleeping: false, competingPolicy: false)
        XCTAssertEqual(clock, .hold(.provisionalIdentity))
        let definition = DisplayIntegration(id: numeric, enabled: true)
        let config = IntegrationConfiguration(displays: [definition])
        let displays = AutomationDisplaySet(candidates: [.init(id: numeric, name: "Replacement", availability: .active)])
        XCTAssertNil(IntegrationPlan.definition(for: numeric, in: config, displays: displays))
        let awake = DisplaySleepPrevention.decide(anyExternal: false, perDisplay: [numeric.rawValue],
            candidates: [.init(recordID: numeric, displayClass: .external, isActive: true,
                               physicalPresence: .physical)])
        XCTAssertFalse(awake.shouldHold)
    }

    func testStableObservationStillRequiresUnambiguousRegistryEvidence() {
        let stable = DisplayRecordID.forCGUUID("A")
        var record = DisplayRecord(id: .generate(), fingerprint: .init(), displayClass: .external, lastSeen: Date())
        XCTAssertFalse(PersistentDisplayIdentity.isVerified(numeric, record: record))
        XCTAssertFalse(PersistentDisplayIdentity.isVerified(stable, record: nil))
        XCTAssertTrue(PersistentDisplayIdentity.isVerified(stable, record: record))
        record.unresolvedCandidates = []
        XCTAssertFalse(PersistentDisplayIdentity.isVerified(stable, record: record))
        for raw in ["", "cg:", "unresolved:A", "cgid:7"] {
            XCTAssertFalse(PersistentDisplayIdentity.isPersistent(.init(rawValue: raw)))
        }
    }
}
