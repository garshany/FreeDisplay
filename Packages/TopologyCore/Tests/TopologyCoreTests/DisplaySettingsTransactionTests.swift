import XCTest
import DisplayDomain
@testable import TopologyCore

final class DisplaySettingsTransactionTests: XCTestCase {
    private enum Fault: Error { case injected }

    @MainActor
    func testConcurrentSettingAndGroupOffsetEditsAbortTransferWithoutLosingMemoryOrDisk() async throws {
        for groupOffset in [false, true] {
            for registryFails in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let source = DisplayRecord(id: .init(rawValue: "disp_source"), fingerprint: .init(),
                    displayClass: .external, lastSeen: Date())
                var startingSettings = OpenDisplaySettings.default
                startingSettings.displayGroups = [.init(name: "Desk", memberRecordIDs: [.forCGUUID("OTHER")])]
                let original = DisplaySettingsRecoverySnapshot(settings: startingSettings, favorites: .init(),
                    menuLayout: .default, managedOffline: [], registry: .init(records: [source]))
                var memory = original
                var disk = original
                var updated = original
                updated.settings.keyboardAudioByDisplay["cg:DEST"] = .init(nativeAudioDevice: "USB")
                updated.registry.records = []
                var published = false
                do {
                    try await DisplaySettingsTransaction.run(snapshot: original,
                        recoveryURL: directory.appendingPathComponent("recovery.json"), write: { step in
                            if step == .settings { disk.settings = updated.settings }
                            if step == .registry {
                                disk.registry = updated.registry
                                // A different main-actor writer runs while registry persistence yields.
                                await Task { @MainActor in
                                    if groupOffset {
                                        memory.settings.displayGroups[0].offsetByMember["cg:OTHER"] = 0.25
                                    } else {
                                        memory.settings.mediaKeyInterceptionEnabled.toggle()
                                    }
                                    disk.settings = memory.settings
                                }.value
                                if registryFails { throw Fault.injected }
                            }
                        }, commit: {
                            try DisplaySettingsTransaction.commitIfUnchanged(expected: original, current: memory,
                                persist: { disk = updated }, publish: { memory = updated; published = true })
                        }, restore: { step in
                            switch step {
                            case .settings: disk.settings = memory.settings
                            case .favorites: disk.favorites = memory.favorites
                            case .menuLayout: disk.menuLayout = memory.menuLayout
                            case .managedOffline: disk.managedOffline = memory.managedOffline
                            case .registry: disk.registry = original.registry
                            }
                        })
                    XCTFail("a concurrent edit or registry error must abort")
                } catch let failure as DisplaySettingsTransaction.Failure {
                    XCTAssertTrue(failure.restored)
                    if !registryFails { XCTAssertTrue(failure.underlying is DisplaySettingsTransaction.StateChanged) }
                }
                XCTAssertFalse(published)
                XCTAssertNotEqual(memory.settings, original.settings)
                XCTAssertEqual(disk, memory)
                XCTAssertEqual(disk.registry.records, [source])
                XCTAssertNil(memory.settings.keyboardAudioByDisplay["cg:DEST"])
            }
        }
    }

    @MainActor
    func testUnchangedStateSaveDuringRegistryIOCannotUndoSuccessfulTransferOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DisplaySettingsRecoverySnapshot(settings: .default, favorites: .init(),
            menuLayout: .default, managedOffline: [], registry: .init())
        var memory = original
        var disk = original
        var updated = original
        updated.settings.keyboardAudioByDisplay["cg:DEST"] = .init(nativeAudioDevice: "USB")
        try await DisplaySettingsTransaction.run(snapshot: original,
            recoveryURL: directory.appendingPathComponent("recovery.json"), write: { step in
                if step == .settings { disk.settings = updated.settings }
                if step == .registry {
                    await Task { @MainActor in disk.settings = memory.settings }.value
                }
            }, commit: {
                try DisplaySettingsTransaction.commitIfUnchanged(expected: original, current: memory,
                    persist: { disk = updated }, publish: { memory = updated })
            }, restore: { _ in XCTFail("successful transfer must not roll back") })
        XCTAssertEqual(memory, updated)
        XCTAssertEqual(disk, updated)
    }

    @MainActor
    func testFinalPersistenceFailureRestoresEveryStoreBeforeAnyPublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = DisplaySettingsRecoverySnapshot(settings: .default, favorites: .init(),
            menuLayout: .default, managedOffline: [], registry: .init())
        var published = false
        var restored: [DisplaySettingsTransaction.Step] = []
        do {
            try await DisplaySettingsTransaction.run(snapshot: original,
                recoveryURL: directory.appendingPathComponent("recovery.json"), write: { _ in }, commit: {
                    try DisplaySettingsTransaction.commitIfUnchanged(expected: original, current: original,
                        persist: { throw Fault.injected }, publish: { published = true })
                }, restore: { restored.append($0) })
            XCTFail("final persistence failure must not commit")
        } catch let failure as DisplaySettingsTransaction.Failure { XCTAssertTrue(failure.restored) }
        XCTAssertFalse(published)
        XCTAssertEqual(restored, DisplaySettingsTransaction.Step.allCases.reversed())
    }

    @MainActor
    func testEveryPersistenceFailureRollsBackAndNeverCommitsSourceRemovalEarly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = OpenDisplaySettings()
        settings.keyboardAudioByDisplay["cg:OLD"] = .init(nativeAudioDevice: "USB-A")
        let source = DisplayRecord(id: .init(rawValue: "disp_source"), alias: "Original",
                                   fingerprint: .init(), displayClass: .external, lastSeen: Date())
        let snapshot = DisplaySettingsRecoverySnapshot(settings: settings, favorites: .init(), menuLayout: .default,
            managedOffline: [], registry: .init(records: [source], cgUUIDIndex: ["OLD": source.id]))
        for failurePoint in DisplaySettingsTransaction.Step.allCases {
            var changed: [DisplaySettingsTransaction.Step] = []
            var writes: [DisplaySettingsTransaction.Step] = []
            let backup = directory.appendingPathComponent("\(failurePoint).json")
            do {
                try await DisplaySettingsTransaction.run(snapshot: snapshot, recoveryURL: backup,
                    write: { step in
                        writes.append(step)
                        if step == .registry { XCTAssertEqual(writes, DisplaySettingsTransaction.Step.allCases) }
                        changed.append(step) // also covers memory published before a failing save
                        if step == failurePoint { throw Fault.injected }
                    }, restore: { step in changed.removeAll { $0 == step } })
                XCTFail("a failed save must never report success")
            } catch let failure as DisplaySettingsTransaction.Failure {
                XCTAssertTrue(failure.restored)
                XCTAssertEqual(failure.recoveryURL, backup)
            }
            XCTAssertTrue(changed.isEmpty)
            let recovered = try JSONDecoder().decode(DisplaySettingsRecoverySnapshot.self, from: Data(contentsOf: backup))
            XCTAssertEqual(recovered, snapshot)
            if failurePoint != .registry { XCTAssertFalse(writes.contains(.registry)) }
        }
    }

    @MainActor
    func testBackupFailureWritesNothingAndRollbackFailureKeepsRecoverySnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = DisplaySettingsRecoverySnapshot(settings: .default, favorites: .init(), menuLayout: .default,
                                                        managedOffline: [], registry: .init())
        var wrote = false
        do {
            try await DisplaySettingsTransaction.run(snapshot: snapshot, recoveryURL: directory,
                write: { _ in wrote = true }, restore: { _ in XCTFail("nothing reached") })
            XCTFail("directory cannot be a recovery file")
        } catch { XCTAssertFalse(wrote) }
        let backup = directory.appendingPathComponent("recovery.json")
        var restored: [DisplaySettingsTransaction.Step] = []
        do {
            try await DisplaySettingsTransaction.run(snapshot: snapshot, recoveryURL: backup,
                write: { if $0 == .menuLayout { throw Fault.injected } },
                restore: { step in
                    restored.append(step)
                    if step == .favorites { throw Fault.injected }
                })
            XCTFail("write failed")
        } catch let failure as DisplaySettingsTransaction.Failure { XCTAssertFalse(failure.restored) }
        XCTAssertEqual(restored, [.menuLayout, .favorites, .settings])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }
}

private actor RejectingTransferRegistryStore: RegistryStoring {
    let original: RegistryState
    init(_ state: RegistryState) { original = state }
    func load() -> RegistryState { original }
    func save(_ state: RegistryState) throws { throw CocoaError(.fileWriteOutOfSpace) }
}

extension DisplaySettingsTransactionTests {
    func testRegistryWriteFailurePreservesSourceRecordAndUUIDIndex() async {
        let a = DisplayRecord(id: .init(rawValue: "disp_A"), alias: "A", fingerprint: .init(),
                              displayClass: .external, lastSeen: Date())
        let b = DisplayRecord(id: .init(rawValue: "disp_B"), alias: "B", fingerprint: .init(),
                              displayClass: .external, lastSeen: Date())
        let original = RegistryState(records: [a, b], cgUUIDIndex: ["A": a.id, "B": b.id])
        let registry = await DisplayRegistry(store: RejectingTransferRegistryStore(original))
        let result = await registry.transferUserData(from: a.id, to: b.id, alias: true, tags: true,
            provenance: .init(kind: .transferredFrom, date: Date(), sourceName: "A", sourceRecordID: a.id,
                              sourceObservationIDs: [.forCGUUID("A")], categories: ["name"]))
        XCTAssertNil(result)
        let state = await registry.currentState()
        XCTAssertEqual(state, original)
    }
}
