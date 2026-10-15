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
    func testRenameReportsUnknownRecord() async {
        let registry = await DisplayRegistry(store: InMemoryRegistryStore())
        do {
            try await registry.setAlias("Lost rename", for: .init(rawValue: "missing"))
            XCTFail("an unknown rename target must report failure")
        } catch { }
    }

    func testRenameWriteFailureRestoresPersistentAndProvisionalRecords() async throws {
        for provisional in [false, true] {
            let remembered = DisplayRecord(id: .init(rawValue: "disp_A"), alias: "Original",
                fingerprint: .init(), displayClass: .external, lastSeen: Date())
            let original = RegistryState(records: [remembered], cgUUIDIndex: ["A": remembered.id])
            let store = RejectingTransferRegistryStore(original)
            let registry = await DisplayRegistry(store: store)
            let target: DisplayRecord
            if provisional {
                target = await registry.resolveAllExplained([
                    (.init(vendorID: 99, productID: 99), "PROVISIONAL", .external)
                ], newRecordStrategy: .qualifiedSerial)[0].record
                XCTAssertTrue(target.isProvisional)
            } else {
                target = remembered
            }
            do {
                try await registry.setAlias("Unsaved", for: target.id)
                XCTFail("a rejected save must report failure")
            } catch {
                XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace)
            }
            let current = await registry.currentState()
            let after = await registry.record(for: target.id)
            let saved = await store.load()
            XCTAssertEqual(current, original, "a failed rename cannot publish a materialized record or UUID binding")
            XCTAssertEqual(saved, original)
            XCTAssertEqual(after, target, "the prior provisional ID must remain available after a failed rename")
        }
    }

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

/// The first save stops inside the backend, so tests exercise actor reentrancy without clocks.
private actor PausingTransferRegistryStore: RegistryStoring {
    private var state: RegistryState
    private var paused = false
    private var didPause = false
    private var pauseEnabled = false
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []
    private var resumeSave: CheckedContinuation<Void, Never>?
    private let failPausedSave: Bool

    init(_ state: RegistryState, failPausedSave: Bool) {
        self.state = state
        self.failPausedSave = failPausedSave
    }
    func load() -> RegistryState { state }
    func save(_ state: RegistryState) async throws {
        if pauseEnabled && !didPause {
            didPause = true
            await withCheckedContinuation { continuation in
                resumeSave = continuation
                paused = true
                for observer in pauseObservers { observer.resume() }
                pauseObservers.removeAll()
            }
            if failPausedSave { throw CocoaError(.fileWriteOutOfSpace) }
        }
        self.state = state
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseObservers.append($0) }
    }
    func pauseNextSave() { pauseEnabled = true }
    func resume() {
        resumeSave?.resume()
        resumeSave = nil
    }
}

extension DisplaySettingsTransactionTests {
    @MainActor
    func testTransferRollbackSerializesConcurrentRenameAndPreservesOrdinarySettingEdit() async throws {
        for (provisionalC, storageFailure) in [(false, false), (false, true), (true, false), (true, true)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let a = DisplayRecord(id: .init(rawValue: "disp_A"), alias: "A", fingerprint: .init(),
                                  displayClass: .external, lastSeen: Date())
            let b = DisplayRecord(id: .init(rawValue: "disp_B"), alias: "B", fingerprint: .init(),
                                  displayClass: .external, lastSeen: Date())
            let c = DisplayRecord(id: .init(rawValue: "disp_C"), alias: "C", fingerprint: .init(),
                                  displayClass: .external, lastSeen: Date())
            let original = RegistryState(records: provisionalC ? [a, b] : [a, b, c],
                cgUUIDIndex: provisionalC ? ["A": a.id, "B": b.id] : ["A": a.id, "B": b.id, "C": c.id])
            let store = PausingTransferRegistryStore(original, failPausedSave: storageFailure)
            let registry = await DisplayRegistry(store: store)
            let renameID: DisplayRecordID
            if provisionalC {
                let resolved = await registry.resolveAllExplained([
                    (.init(vendorID: 99, productID: 99), "PROVISIONAL_C", .external)
                ], newRecordStrategy: .qualifiedSerial)
                XCTAssertTrue(resolved[0].record.isProvisional)
                renameID = resolved[0].record.id
            } else {
                renameID = c.id
            }
            await store.pauseNextSave()
            let lease = await registry.beginMutationLease()
            let registrySnapshot = await registry.mutationSnapshot(lease: lease)
            let snapshot = DisplaySettingsRecoverySnapshot(settings: .default, favorites: .init(),
                menuLayout: .default, managedOffline: [], registry: registrySnapshot.persistentState)
            var memory = snapshot
            var disk = snapshot
            var rename: Task<Void, Error>?
            var renamed = false
            var published = false
            do {
                try await DisplaySettingsTransaction.run(snapshot: snapshot,
                    recoveryURL: directory.appendingPathComponent("recovery.json"), write: { step in
                        if step == .settings { disk.settings.keyboardAudioByDisplay["cg:B"] = .init(nativeAudioDevice: "USB") }
                        if step == .registry {
                            let transfer = Task {
                                try await registry.transferUserDataPersisting(from: a.id, to: b.id,
                                    alias: true, tags: true,
                                    provenance: .init(kind: .transferredFrom, date: Date(), sourceName: "A",
                                        sourceRecordID: a.id, sourceObservationIDs: [.forCGUUID("A")], categories: ["name"]),
                                    lease: lease)
                            }
                            await store.waitUntilPaused()
                            rename = Task {
                                try await registry.setAlias("C renamed", for: renameID)
                                renamed = true
                            }
                            // Observe either actual admission to the queue or the pre-fix edit
                            // finishing; no scheduler timing assumption or timeout is required.
                            while await registry.pendingMutationCount == 0 && !renamed { await Task.yield() }
                            memory.settings.mediaKeyInterceptionEnabled.toggle()
                            disk.settings = memory.settings
                            await store.resume()
                            _ = try await transfer.value
                        }
                    }, commit: {
                        try DisplaySettingsTransaction.commitIfUnchanged(expected: snapshot, current: memory,
                            persist: { XCTFail("conflict must precede final saves") }, publish: { published = true })
                    }, restore: { step in
                        switch step {
                        case .registry: try await registry.restoreMutationSnapshot(registrySnapshot, lease: lease)
                        case .settings: disk.settings = memory.settings
                        case .favorites: disk.favorites = memory.favorites
                        case .menuLayout: disk.menuLayout = memory.menuLayout
                        case .managedOffline: disk.managedOffline = memory.managedOffline
                        }
                    })
                XCTFail("conflicting edit or failed store must abort")
            } catch let failure as DisplaySettingsTransaction.Failure {
                XCTAssertTrue(failure.restored)
                if !storageFailure { XCTAssertTrue(failure.underlying is DisplaySettingsTransaction.StateChanged) }
            }
            XCTAssertFalse(renamed, "rollback must finish before the queued rename runs")
            if provisionalC {
                let pending = await registry.record(for: renameID)
                XCTAssertTrue(pending?.isProvisional == true, "restore live answers before releasing the lease")
            }
            await registry.endMutationLease(lease)
            try await rename?.value
            XCTAssertFalse(published)
            XCTAssertEqual(disk.settings, memory.settings)
            XCTAssertNotEqual(memory.settings, snapshot.settings)
            var expected = original
            let current = await registry.currentState()
            if provisionalC {
                guard let materialized = current.records.first(where: { $0.alias == "C renamed" }) else {
                    XCTFail("rollback lost the queued provisional rename (storage failure: \(storageFailure))")
                    continue
                }
                XCTAssertFalse(materialized.isProvisional)
                XCTAssertNotEqual(materialized.id, renameID)
                expected.records.append(materialized)
                expected.cgUUIDIndex["PROVISIONAL_C"] = materialized.id
            } else {
                expected.records[2].alias = "C renamed"
            }
            let saved = await store.load()
            XCTAssertEqual(current, expected, "rollback restores A/B while the unrelated rename survives")
            XCTAssertEqual(saved, expected)
        }
    }

    @MainActor
    func testTransferLeaseWaitsForRegistryWriterAlreadyPersisting() async throws {
        let c = DisplayRecord(id: .init(rawValue: "disp_C"), alias: "C", fingerprint: .init(),
                              displayClass: .external, lastSeen: Date())
        let store = PausingTransferRegistryStore(.init(records: [c]), failPausedSave: false)
        let registry = await DisplayRegistry(store: store)
        await store.pauseNextSave()
        let rename = Task { try await registry.setAlias("C renamed", for: c.id) }
        await store.waitUntilPaused()
        var acquired = false
        let transfer = Task {
            let lease = await registry.beginMutationLease()
            acquired = true
            let snapshot = await registry.currentState()
            await registry.endMutationLease(lease)
            return snapshot
        }
        while await registry.pendingMutationCount == 0 && !acquired { await Task.yield() }
        XCTAssertFalse(acquired, "a transfer snapshot cannot precede an in-flight registry writer")
        await store.resume()
        try await rename.value
        let snapshot = await transfer.value
        XCTAssertEqual(snapshot.records.first?.alias, "C renamed")
        let saved = await store.load()
        XCTAssertEqual(saved, snapshot)
    }
}
