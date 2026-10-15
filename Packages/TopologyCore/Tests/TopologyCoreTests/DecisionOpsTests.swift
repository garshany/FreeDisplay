import DisplayDomain
import Foundation
import XCTest
@testable import TopologyCore

final class AutoDisconnectEligibilityTests: XCTestCase {
    private func display(_ kind: DisplayClass = .external, _ presence: PhysicalPresence? = .physical,
                         active: Bool = true) -> DisplayObservation {
        DisplayObservation(recordID: .forCGUUID("A"), isActive: active, displayClass: kind,
                           physicalPresence: presence, generation: .initial)
    }

    func testOnlyConfirmedActiveNativeExternalTriggers() {
        for kind in [DisplayClass.external, .television, .projector] {
            XCTAssertTrue(AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: [display(kind)]))
        }
        for kind in [DisplayClass.builtIn, .sidecar, .airplay, .virtual, .headlessAdapter, .unknown] {
            XCTAssertFalse(AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: [display(kind)]))
        }
        for presence in [PhysicalPresence.virtual, .unverified] {
            XCTAssertFalse(AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: [display(.external, presence)]))
        }
        XCTAssertFalse(AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: [display(.external, nil)]))
        XCTAssertFalse(AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: [display(active: false)]))
    }

    func testVirtualOrDisplayLinkArrivalDoesNotConsumeThePhysicalArrivalEdge() {
        var policy = AutoDisconnectBuiltInPolicy()
        for observation in [display(.virtual, .virtual), display(.external, .unverified), display(.sidecar, .unverified)] {
            XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent:
                AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: [observation])))
        }
        XCTAssertTrue(policy.onTopologyChange(enabled: true, externalPresent:
            AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: [display()])))
        XCTAssertFalse(policy.onTopologyChange(enabled: true, externalPresent:
            AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: [display()])))
    }
}

final class DDCBindingPopulationTests: XCTestCase {
    private let target = DDCServiceMatcher.Target(vendorNumber: 1, productNumber: 2, serialNumber: 3)
    private func offline(_ uuid: String = "A", kind: DisplayClass = .external) -> ManagedOfflineDisplay {
        ManagedOfflineDisplay(recordID: .forCGUUID(uuid), cgID: 7, name: uuid, displayClass: kind)
    }

    func testOffMonitorBlocksSoleServiceBinding() {
        let count = DDCBindingPopulation.unobservedExternalCount(observations: [], ledger: [offline()])
        XCTAssertEqual(count, 1)
        XCTAssertEqual(DDCServiceMatcher.resolve([nil], against: target, among: [target],
                                                unobservedExternalCount: count), .refused(.unidentified))
        XCTAssertEqual(DDCServiceMatcher.resolve([nil], against: target, among: [target]), .sole(index: 0))
    }

    func testMirroredOrRenumberedLedgerDisplayIsNotCountedTwice() {
        let live = DisplayObservation(recordID: .forCGUUID("a"), cgDisplayID: 12, cgUUID: "a",
                                      isActive: true, generation: .initial)
        XCTAssertEqual(DDCBindingPopulation.unobservedExternalCount(observations: [live], ledger: [offline()]), 0)
        XCTAssertEqual(DDCBindingPopulation.unobservedExternalCount(observations: [], ledger: [offline(), offline()]), 1)
    }

    func testBuiltInAndOwnVirtualAreNotExternalServiceOwners() {
        XCTAssertEqual(DDCBindingPopulation.unobservedExternalCount(observations: [],
            ledger: [offline("B", kind: .builtIn), offline("V", kind: .virtual)]), 0)
    }

    func testReusedNumberDoesNotHideAnOfflineMonitor() {
        let other = DisplayObservation(recordID: .forCGUUID("B"), cgDisplayID: 7, cgUUID: "B",
                                       isActive: true, generation: .initial)
        XCTAssertEqual(DDCBindingPopulation.unobservedExternalCount(observations: [other], ledger: [offline()]), 1)
    }

    func testPositiveExclusiveIdentityStillBindsWithOfflineDisplays() {
        XCTAssertEqual(DDCServiceMatcher.resolve([.init(legacyManufacturerID: 1, productID: 2, serialNumber: 3)],
            against: target, among: [target], unobservedExternalCount: 1), .matched(index: 0))
    }
}

final class RescueIdentitySelectionTests: XCTestCase {
    private func observation(uuid: String? = "A", number: UInt32 = 7) -> DisplayObservation {
        DisplayObservation(recordID: uuid.map(DisplayRecordID.forCGUUID) ?? .init(rawValue: "cgid:\(number)"),
                           cgDisplayID: number, cgUUID: uuid, isActive: true, generation: .initial)
    }

    func testPersistentIdentityWinsOverReusedCheckpointNumber() throws {
        let result = try ReconnectIdentity.recoveryTarget(for: observation(), ledger: [],
            numberForUUID: { _ in 12 }, uuidForNumber: { $0 == 12 ? "a" : "B" })
        XCTAssertEqual(result.rawValue, "cgid:12")
    }

    func testDarkDisplayNumberRequiresPositiveUUIDEvidence() throws {
        XCTAssertEqual(try ReconnectIdentity.recoveryTarget(for: observation(), ledger: [],
            numberForUUID: { _ in nil }, uuidForNumber: { _ in "A" }).rawValue, "cgid:7")
        XCTAssertThrowsError(try ReconnectIdentity.recoveryTarget(for: observation(), ledger: [],
            numberForUUID: { _ in nil }, uuidForNumber: { _ in nil }))
        XCTAssertThrowsError(try ReconnectIdentity.recoveryTarget(for: observation(), ledger: [],
            numberForUUID: { _ in nil }, uuidForNumber: { _ in "B" }))
    }

    func testRawCheckpointNumberAloneNeverAuthorizesRecovery() {
        XCTAssertThrowsError(try ReconnectIdentity.recoveryTarget(for: observation(uuid: nil), ledger: [],
            numberForUUID: { _ in nil }, uuidForNumber: { _ in "A" }))
    }

    func testForwardUUIDLookupMustAlsoRoundTrip() {
        XCTAssertThrowsError(try ReconnectIdentity.recoveryTarget(for: observation(), ledger: [],
            numberForUUID: { _ in 12 }, uuidForNumber: { _ in "B" }))
    }

    func testLaterLedgerOwnershipConflictIsStillRespected() {
        let ledger = [ManagedOfflineDisplay(recordID: .forCGUUID("A"), cgID: 7, name: "A", displayClass: .external),
                      ManagedOfflineDisplay(recordID: .forCGUUID("B"), cgID: 7, name: "B", displayClass: .external)]
        XCTAssertThrowsError(try ReconnectIdentity.recoveryTarget(for: observation(), ledger: ledger,
            numberForUUID: { _ in nil }, uuidForNumber: { _ in "A" }))
    }

    func testContradictoryCheckpointUUIDFieldsAreRefused() {
        var corrupted = observation()
        corrupted.cgUUID = "B"
        XCTAssertThrowsError(try ReconnectIdentity.recoveryTarget(for: corrupted, ledger: [],
            numberForUUID: { _ in 12 }, uuidForNumber: { _ in "B" }))
    }

    func testUUIDMetadataCanIdentifyALegacyRawRecord() throws {
        var legacy = observation()
        legacy.recordID = .init(rawValue: "cgid:7")
        XCTAssertEqual(try ReconnectIdentity.recoveryTarget(for: legacy, ledger: [],
            numberForUUID: { _ in 12 }, uuidForNumber: { _ in "A" }).rawValue, "cgid:12")
    }
}

final class RevertRecordPresentationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func obs(_ id: String, main: Bool = false) -> DisplayObservation {
        DisplayObservation(recordID: .forCGUUID(id), isActive: true,
                           origin: .init(x: 1920, y: 0), isMain: main, generation: .initial)
    }

    func testPresentsAllRecordedSettingsAndAwaitedDisplays() {
        let a = obs("A", main: true), b = obs("B")
        let record = RevertRecord(observations: [a, b], createdAt: date)
        let presentation = RevertRecordPresentation(record: record, current: [a])
        XCTAssertTrue(presentation.readable)
        XCTAssertEqual(presentation.createdAt, date)
        XCTAssertEqual(presentation.entries.map(\.awaitingDisplay), [false, true])
        XCTAssertEqual(presentation.entries.map(\.observation), [a, b])
    }

    func testNarrowingToAbsentDisplaysPreservesOriginalDate() throws {
        let a = obs("A"), b = obs("B")
        let record = RevertRecord(observations: [a, b], createdAt: date)
        let kept = try XCTUnwrap(record.retaining(after: .restored(providerWarnings: [], mismatches: [.absent(b.recordID)])))
        XCTAssertEqual(kept.observations, [b])
        XCTAssertEqual(kept.createdAt, date)
        XCTAssertEqual(RevertRecord.decode(try JSONEncoder().encode(kept), legacyDate: nil), kept)
        XCTAssertNil(record.retaining(after: .kept))
    }

    func testLegacyArraysUseFileDateWithoutInventingAnAge() throws {
        let data = try JSONEncoder().encode([obs("A")])
        XCTAssertEqual(RevertRecord.decode(data, legacyDate: date)?.createdAt, date)
        XCTAssertNil(RevertRecord.decode(data, legacyDate: nil)?.createdAt)
    }

    func testWindowServerOnlyDisplayIsNotPresentedAsAwaited() {
        var virtual = obs("V")
        virtual.physicalPresence = .virtual
        let record = RevertRecord(observations: [virtual], createdAt: date)
        XCTAssertFalse(RevertRecordPresentation(record: record, current: []).entries[0].awaitingDisplay)
    }

    func testUnreadableRecordRemainsPresentableForExplicitForget() {
        XCTAssertNil(RevertRecord.decode(Data("broken".utf8), legacyDate: nil))
        let presentation = RevertRecordPresentation(record: nil, current: [])
        XCTAssertFalse(presentation.readable)
        XCTAssertTrue(presentation.entries.isEmpty)
    }
}
