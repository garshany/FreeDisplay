import XCTest
import DisplayDomain
@testable import TopologyCore

final class DisplaySettingsTransactionTests: XCTestCase {
    private enum Fault: Error { case injected }

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
